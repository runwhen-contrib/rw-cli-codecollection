#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Check Apigee API Latency Performance
#
# Queries proxyv2/percentile latency metrics and raises ONE finding that lists
# every proxy whose p95/p99 latency exceeds LATENCY_MS_THRESHOLD.
#
# Issue titles carry the failure mode and the org, never a proxy name or a
# latency value -- see check_error_rates.sh for why.
#
# REQUIRED ENV VARS:
#   GCP_PROJECT_ID            - GCP project hosting the Apigee runtime
#
# OPTIONAL ENV VARS:
#   APIGEE_ORG                - Apigee org name; falls back to the org recorded
#                               in the scope file
#   LATENCY_MS_THRESHOLD      - p95 latency threshold in ms (default 500)
#   METRIC_WINDOW_MIN         - Lookback window in minutes (default 60)
#   MOCK_DATA_FILE            - Path to mock latency data (deterministic tests)
#   APIGEE_SCOPE_FILE         - Path to scope JSON (default apigee_scope.json)
#
# OUTPUTS:
#   latency_issues.json      - JSON array of issues
#   latency_report.json      - Per-proxy latency values
# -----------------------------------------------------------------------------
set -euo pipefail
set -x

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
: "${APIGEE_ORG:=}"
: "${LATENCY_MS_THRESHOLD:=500}"
: "${METRIC_WINDOW_MIN:=60}"
: "${APIGEE_SCOPE_FILE:=apigee_scope.json}"

ISSUES_FILE="latency_issues.json"
REPORT_FILE="latency_report.json"
issues_json='[]'
report_json='[]'
offenders=""

window_seconds=$(( METRIC_WINDOW_MIN * 60 ))
now_epoch=$(date +%s)
start_epoch=$(( now_epoch - window_seconds ))
# GNU date takes -d @<epoch>; BSD/macOS date takes -r <epoch>. The runner is
# Linux, but the offline tier runs on a developer's machine too, and a script
# that aborts under `set -e` before it queries anything is untestable there.
iso_utc() {
    date -u -d "@$1" "+%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
        || date -u -r "$1" "+%Y-%m-%dT%H:%M:%SZ"
}
start_time=$(iso_utc "${start_epoch}")
end_time=$(iso_utc "${now_epoch}")

# ---------------------------------------------------------------------------
# Mock path (deterministic tests)
# Expected format: array of {"proxy","p50_ms","p90_ms","p95_ms","p99_ms"}
# ---------------------------------------------------------------------------
if [ -n "${MOCK_DATA_FILE:-}" ] && [ -f "${MOCK_DATA_FILE}" ]; then
    [ -z "${APIGEE_ORG}" ] && APIGEE_ORG="mock-org"
    echo "Analyzing Apigee latency for org: ${APIGEE_ORG} (p95 threshold: ${LATENCY_MS_THRESHOLD}ms, window: ${METRIC_WINDOW_MIN}m)"
    echo "Using mock latency data from ${MOCK_DATA_FILE}"
    while IFS= read -r row; do
        [ -z "${row}" ] && continue
        proxy=$(echo "${row}" | jq -r '.proxy')
        p50=$(echo "${row}" | jq -r '.p50_ms // 0')
        p90=$(echo "${row}" | jq -r '.p90_ms // 0')
        p95=$(echo "${row}" | jq -r '.p95_ms // 0')
        p99=$(echo "${row}" | jq -r '.p99_ms // 0')
        echo "  proxy '${proxy}': p50=${p50}ms p90=${p90}ms p95=${p95}ms p99=${p99}ms"
        report_json=$(echo "${report_json}" | jq \
            --arg proxy "${proxy}" --arg p50 "${p50}" --arg p95 "${p95}" --arg p99 "${p99}" \
            '. += [{"proxy":$proxy,"p50_ms":($p50|tonumber),"p95_ms":($p95|tonumber),"p99_ms":($p99|tonumber)}]')
        exceeded=$(awk -v p="${p95}" -v p9="${p99}" -v thr="${LATENCY_MS_THRESHOLD}" 'BEGIN { print (p > thr || p9 > thr) ? "1" : "0" }')
        if [ "${exceeded}" = "1" ]; then
            offenders="${offenders}  - ${proxy}: p95 ${p95}ms, p99 ${p99}ms
"
        fi
    done < <(jq -c '.[]' "${MOCK_DATA_FILE}")

# ---------------------------------------------------------------------------
# Live path: Cloud Monitoring
# ---------------------------------------------------------------------------
else
    # Discovery runs in Suite Initialization and fails the suite when it cannot
    # produce a scope, so a missing file means this check has been run against
    # nothing. Reporting that as "no issues found" is the blind-run-passes bug.
    if [ ! -f "${APIGEE_SCOPE_FILE}" ]; then
        echo "ERROR: ${APIGEE_SCOPE_FILE} is missing. Discovery runs in Suite Initialization;" >&2
        echo "       if you are running this script directly, run discover_metrics_scope.sh first." >&2
        exit 1
    fi
    if [ -z "${APIGEE_ORG}" ]; then
        APIGEE_ORG=$(jq -r '.organization // ""' "${APIGEE_SCOPE_FILE}" 2>/dev/null || echo "")
    fi
    echo "Analyzing Apigee latency for org: ${APIGEE_ORG} (p95 threshold: ${LATENCY_MS_THRESHOLD}ms, window: ${METRIC_WINDOW_MIN}m)"

    # xtrace is suppressed around every use of the token. `set -x` would
    # otherwise write a live OAuth bearer token into the task's captured
    # output -- at the ASSIGNMENT as well as at the request, so wrapping only
    # the curl is insufficient.
    { set +x; } 2>/dev/null
    access_token=$(gcloud auth print-access-token 2>/dev/null || echo "")
    # The emptiness test runs BEFORE tracing is restored. Re-enabling first
    # would put `+ [ -z ya29.a0Af... ]` in the trace -- the same leak, moved.
    if [ -n "${access_token}" ]; then have_token=1; else have_token=0; fi
    set -x
    if [ "${have_token}" = "0" ]; then
        issues_json=$(echo "${issues_json}" | jq \
            --arg title "Cannot query Cloud Monitoring for Apigee latency in org \`${APIGEE_ORG}\`" \
            --arg details "Unable to obtain an access token via gcloud for the Cloud Monitoring API in project ${GCP_PROJECT_ID}. No proxy was evaluated, so this run determined nothing about latency." \
            --arg severity "4" \
            --arg expected "Cloud Monitoring metrics should be retrievable." \
            --arg actual "Could not obtain an access token, so no proxy was evaluated." \
            --arg next_steps "Ensure the service account has roles/monitoring.viewer and that Suite Initialization's token probe passed." \
            '. += [{"title":$title,"details":$details,"severity":($severity|tonumber),"expected":$expected,"actual":$actual,"next_steps":$next_steps}]')
        echo "${issues_json}" > "${ISSUES_FILE}"
        echo "[]" > "${REPORT_FILE}"
        exit 0
    fi

    query_metric_p95_ms() {
        local metric_type="$1"
        local extra_filter="$2"
        local filter="metric.type=\"${metric_type}\""
        if [ -n "${extra_filter}" ]; then
            filter="${filter} AND ${extra_filter}"
        fi
        local encoded
        encoded=$(jq -rn --arg v "${filter}" '$v|@uri')
        local url="https://monitoring.googleapis.com/v3/projects/${GCP_PROJECT_ID}/timeSeries?filter=${encoded}&interval.startTime=${start_time}&interval.endTime=${end_time}&aggregation.alignmentPeriod=60s&aggregation.perSeriesAligner=ALIGN_PERCENTILE_95&aggregation.crossSeriesReducer=REDUCE_PERCENTILE_95&view=FULL"
        local resp
        { set +x; } 2>/dev/null
        resp=$(curl -s -H "Authorization: Bearer ${access_token}" "${url}" 2>/dev/null || echo "{}")
        set -x
        # Value is in seconds; convert to milliseconds.
        echo "${resp}" | jq '[.timeSeries[]?.points[]?.value.doubleValue | tonumber] | max // 0 | . * 1000' 2>/dev/null || echo "0"
    }

    proxies=$(jq -r '.proxies[]?' "${APIGEE_SCOPE_FILE}" 2>/dev/null || true)
    if [ -z "${proxies}" ]; then
        # Positive determination of absence -- not a finding.
        echo "Org '${APIGEE_ORG}' has no API proxies; nothing to evaluate."
        echo "[]" > "${REPORT_FILE}"
        echo "[]" > "${ISSUES_FILE}"
        exit 0
    fi

    while IFS= read -r proxy; do
        [ -z "${proxy}" ] && continue
        filter="metric.label.proxy=\"${proxy}\""
        p95_ms=$(query_metric_p95_ms "apigee.googleapis.com/proxyv2/latencies_percentile" "${filter}")
        p95_ms=$(echo "${p95_ms}" | awk '{printf "%.0f", $1}')
        echo "  proxy '${proxy}': p95 latency ${p95_ms}ms"
        report_json=$(echo "${report_json}" | jq \
            --arg proxy "${proxy}" --arg p95 "${p95_ms}" \
            '. += [{"proxy":$proxy,"p95_ms":($p95|tonumber)}]')
        if [ "${p95_ms}" -gt "${LATENCY_MS_THRESHOLD}" ]; then
            offenders="${offenders}  - ${proxy}: p95 ${p95_ms}ms
"
        fi
    done <<< "${proxies}"
fi

# ---------------------------------------------------------------------------
# One finding per failure mode, listing every offender.
# ---------------------------------------------------------------------------
names() { printf '%s' "$1" | sed 's/^  - //; s/:.*//' | tr '\n' ',' | sed 's/,$//; s/,/, /g'; }
count() { printf '%s' "$1" | grep -c . ; }

if [ -n "${offenders}" ]; then
    issue=$(jq -n \
        --arg title "Apigee proxies have high latency in org \`${APIGEE_ORG}\`" \
        --arg details "The following API proxy/proxies in org ${APIGEE_ORG} (project ${GCP_PROJECT_ID}) exceeded the ${LATENCY_MS_THRESHOLD}ms latency threshold over the last ${METRIC_WINDOW_MIN}m:
${offenders}
Callers of these proxies are seeing slow responses." \
        --arg severity "3" \
        --arg expected "Every Apigee proxy's p95 latency should remain below ${LATENCY_MS_THRESHOLD}ms." \
        --arg actual "$(count "${offenders}") proxy/proxies above the threshold: $(names "${offenders}")." \
        --arg next_steps "Investigate each slow API. Check backend/target performance, quota and rate-limit policies, and whether a recent proxy revision introduced latency. Review the latency percentiles in Cloud Monitoring." \
        '{title:$title,details:$details,severity:($severity|tonumber),expected:$expected,actual:$actual,next_steps:$next_steps}')
    issues_json=$(echo "${issues_json}" | jq --argjson i "${issue}" '. += [$i]')
fi

echo "${report_json}" > "${REPORT_FILE}"
echo "${issues_json}" > "${ISSUES_FILE}"
echo "Latency analysis complete. Found $(jq length "${ISSUES_FILE}") issue(s)."
