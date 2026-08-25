#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Check Apigee Target and Backend Performance
#
# Queries target/upstream request and response metrics to detect slow or failing
# backend target servers, raising ONE finding PER FAILURE MODE that lists every
# affected target:
#
#   1. Target error rate above ERROR_RATE_THRESHOLD
#   2. Target p95 latency above LATENCY_MS_THRESHOLD (mock path only; the live
#      target counters do not expose a latency percentile)
#
# Neither title names a target server or a rate -- see check_error_rates.sh.
#
# REQUIRED ENV VARS:
#   GCP_PROJECT_ID            - GCP project hosting the Apigee runtime
#
# OPTIONAL ENV VARS:
#   APIGEE_ORG                - Apigee org name; falls back to the org recorded
#                               in the scope file
#   ERROR_RATE_THRESHOLD      - Max target error rate in percent (default 5)
#   LATENCY_MS_THRESHOLD      - Target p95 latency threshold in ms (default 500)
#   METRIC_WINDOW_MIN         - Lookback window in minutes (default 60)
#   MOCK_DATA_FILE            - Path to mock target data (deterministic tests)
#   APIGEE_SCOPE_FILE         - Path to scope JSON (default apigee_scope.json)
#
# OUTPUTS:
#   target_performance_issues.json - JSON array of issues
#   target_report.json             - Per-target performance summary
# -----------------------------------------------------------------------------
set -euo pipefail
set -x

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
: "${APIGEE_ORG:=}"
: "${ERROR_RATE_THRESHOLD:=5}"
: "${LATENCY_MS_THRESHOLD:=500}"
: "${METRIC_WINDOW_MIN:=60}"
: "${APIGEE_SCOPE_FILE:=apigee_scope.json}"

ISSUES_FILE="target_performance_issues.json"
REPORT_FILE="target_report.json"
issues_json='[]'
report_json='[]'
erroring=""
slow=""

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
# Expected format: array of {"target","environment","error_rate_percent","p95_latency_ms"}
# ---------------------------------------------------------------------------
if [ -n "${MOCK_DATA_FILE:-}" ] && [ -f "${MOCK_DATA_FILE}" ]; then
    [ -z "${APIGEE_ORG}" ] && APIGEE_ORG="mock-org"
    echo "Analyzing Apigee target/backend performance for org: ${APIGEE_ORG} (window: ${METRIC_WINDOW_MIN}m)"
    echo "Using mock target data from ${MOCK_DATA_FILE}"
    while IFS= read -r row; do
        [ -z "${row}" ] && continue
        target=$(echo "${row}" | jq -r '.target')
        environment=$(echo "${row}" | jq -r '.environment // ""')
        err_rate=$(echo "${row}" | jq -r '.error_rate_percent // 0')
        p95=$(echo "${row}" | jq -r '.p95_latency_ms // 0')
        echo "  target '${target}' (env '${environment}'): error_rate=${err_rate}% p95=${p95}ms"
        report_json=$(echo "${report_json}" | jq \
            --arg target "${target}" --arg environment "${environment}" --arg err "${err_rate}" --arg p95 "${p95}" \
            '. += [{"target":$target,"environment":$environment,"error_rate_percent":($err|tonumber),"p95_latency_ms":($p95|tonumber)}]')
        bad_err=$(awk -v e="${err_rate}" -v thr="${ERROR_RATE_THRESHOLD}" 'BEGIN { print (e > thr) ? "1" : "0" }')
        bad_lat=$(awk -v p="${p95}" -v thr="${LATENCY_MS_THRESHOLD}" 'BEGIN { print (p > thr) ? "1" : "0" }')
        if [ "${bad_err}" = "1" ]; then
            erroring="${erroring}  - ${target} in environment ${environment}: ${err_rate}% error rate
"
        fi
        if [ "${bad_lat}" = "1" ]; then
            slow="${slow}  - ${target} in environment ${environment}: p95 ${p95}ms
"
        fi
    done < <(jq -c '.[]' "${MOCK_DATA_FILE}")

# ---------------------------------------------------------------------------
# Live path: Cloud Monitoring
# ---------------------------------------------------------------------------
else
    # Discovery runs in Suite Initialization; a missing scope means this check
    # looked at nothing, which must not read as "no issues found".
    if [ ! -f "${APIGEE_SCOPE_FILE}" ]; then
        echo "ERROR: ${APIGEE_SCOPE_FILE} is missing. Discovery runs in Suite Initialization;" >&2
        echo "       if you are running this script directly, run discover_metrics_scope.sh first." >&2
        exit 1
    fi
    if [ -z "${APIGEE_ORG}" ]; then
        APIGEE_ORG=$(jq -r '.organization // ""' "${APIGEE_SCOPE_FILE}" 2>/dev/null || echo "")
    fi
    echo "Analyzing Apigee target/backend performance for org: ${APIGEE_ORG} (window: ${METRIC_WINDOW_MIN}m)"

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
            --arg title "Cannot query Cloud Monitoring for Apigee target performance in org \`${APIGEE_ORG}\`" \
            --arg details "Unable to obtain an access token via gcloud for the Cloud Monitoring API in project ${GCP_PROJECT_ID}. No target server was evaluated, so this run determined nothing about backend performance." \
            --arg severity "4" \
            --arg expected "Cloud Monitoring metrics should be retrievable." \
            --arg actual "Could not obtain an access token, so no target server was evaluated." \
            --arg next_steps "Ensure the service account has roles/monitoring.viewer and that Suite Initialization's token probe passed." \
            '. += [{"title":$title,"details":$details,"severity":($severity|tonumber),"expected":$expected,"actual":$actual,"next_steps":$next_steps}]')
        echo "${issues_json}" > "${ISSUES_FILE}"
        echo "[]" > "${REPORT_FILE}"
        exit 0
    fi

    query_metric_count() {
        local metric_type="$1"
        local extra_filter="$2"
        local filter="metric.type=\"${metric_type}\""
        if [ -n "${extra_filter}" ]; then
            filter="${filter} AND ${extra_filter}"
        fi
        local encoded
        encoded=$(jq -rn --arg v "${filter}" '$v|@uri')
        local url="https://monitoring.googleapis.com/v3/projects/${GCP_PROJECT_ID}/timeSeries?filter=${encoded}&interval.startTime=${start_time}&interval.endTime=${end_time}&aggregation.alignmentPeriod=60s&aggregation.perSeriesAligner=ALIGN_SUM&aggregation.crossSeriesReducer=REDUCE_SUM&view=FULL"
        local resp
        { set +x; } 2>/dev/null
        resp=$(curl -s -H "Authorization: Bearer ${access_token}" "${url}" 2>/dev/null || echo "{}")
        set -x
        echo "${resp}" | jq '[.timeSeries[]?.points[]?.value | (.int64Value // .doubleValue // 0) | tonumber] | add // 0' 2>/dev/null || echo "0"
    }

    targets=$(jq -c '.target_servers[]?' "${APIGEE_SCOPE_FILE}" 2>/dev/null || true)
    if [ -z "${targets}" ]; then
        # Positive determination of absence -- not a finding. Note this is only
        # trustworthy because discover_metrics_scope.sh reads the target server
        # list as the BARE ARRAY the API actually returns; the previous
        # `.targetServers[].name` matched nothing, so this branch was taken on
        # every run and the check reported clean without ever looking.
        echo "Org '${APIGEE_ORG}' has no target servers; nothing to evaluate."
        echo "[]" > "${REPORT_FILE}"
        echo "[]" > "${ISSUES_FILE}"
        exit 0
    fi

    while IFS= read -r target_obj; do
        [ -z "${target_obj}" ] && continue
        target=$(echo "${target_obj}" | jq -r '.name')
        environment=$(echo "${target_obj}" | jq -r '.environment // ""')
        filter="metric.label.target_server=\"${target}\""
        [ -n "${environment}" ] && filter="${filter} AND metric.label.environment=\"${environment}\""
        total=$(query_metric_count "apigee.googleapis.com/targetv2/request_count" "${filter}")
        errors=$(query_metric_count "apigee.googleapis.com/targetv2/request_count" "${filter} AND metric.label.response_code_class=\"5xx\"")
        total=$(echo "${total}" | awk '{printf "%.0f", $1}')
        errors=$(echo "${errors}" | awk '{printf "%.0f", $1}')
        # Latency is not available in the target counters; error rate is the
        # signal here. The mock path still exercises the latency mode.
        err_rate=0
        if [ "${total}" -gt 0 ]; then
            err_rate=$(awk -v e="${errors}" -v t="${total}" 'BEGIN { printf "%.2f", (e*100)/t }')
        fi
        echo "  target '${target}' (env '${environment}'): errors=${errors} total=${total} error_rate=${err_rate}%"
        report_json=$(echo "${report_json}" | jq \
            --arg target "${target}" --arg environment "${environment}" --arg err "${err_rate}" \
            '. += [{"target":$target,"environment":$environment,"error_rate_percent":($err|tonumber),"p95_latency_ms":0}]')
        bad_err=$(awk -v e="${err_rate}" -v thr="${ERROR_RATE_THRESHOLD}" 'BEGIN { print (e > thr) ? "1" : "0" }')
        if [ "${bad_err}" = "1" ]; then
            erroring="${erroring}  - ${target} in environment ${environment}: ${err_rate}% error rate
"
        fi
    done <<< "${targets}"
fi

# ---------------------------------------------------------------------------
# One finding per failure mode, listing every affected target.
# ---------------------------------------------------------------------------
names() { printf '%s' "$1" | sed 's/^  - //; s/ in environment.*//' | tr '\n' ',' | sed 's/,$//; s/,/, /g'; }
count() { printf '%s' "$1" | grep -c . ; }

if [ -n "${erroring}" ]; then
    issue=$(jq -n \
        --arg title "Apigee target servers have a high error rate in org \`${APIGEE_ORG}\`" \
        --arg details "The following target server(s) in org ${APIGEE_ORG} (project ${GCP_PROJECT_ID}) exceeded the ${ERROR_RATE_THRESHOLD}% error rate over the last ${METRIC_WINDOW_MIN}m:
${erroring}
Every proxy call routed to them is failing at the southbound edge." \
        --arg severity "3" \
        --arg expected "Every Apigee target server's error rate should remain below ${ERROR_RATE_THRESHOLD}%." \
        --arg actual "$(count "${erroring}") target server(s) above the threshold: $(names "${erroring}")." \
        --arg next_steps "Investigate each listed upstream backend. Check target server health, capacity and configuration, and confirm the backend is responding rather than returning 5xx." \
        '{title:$title,details:$details,severity:($severity|tonumber),expected:$expected,actual:$actual,next_steps:$next_steps}')
    issues_json=$(echo "${issues_json}" | jq --argjson i "${issue}" '. += [$i]')
fi

if [ -n "${slow}" ]; then
    issue=$(jq -n \
        --arg title "Apigee target servers are slow in org \`${APIGEE_ORG}\`" \
        --arg details "The following target server(s) in org ${APIGEE_ORG} (project ${GCP_PROJECT_ID}) exceeded the ${LATENCY_MS_THRESHOLD}ms p95 latency threshold over the last ${METRIC_WINDOW_MIN}m:
${slow}
Proxy latency cannot be better than its slowest backend." \
        --arg severity "3" \
        --arg expected "Every Apigee target server's p95 latency should remain below ${LATENCY_MS_THRESHOLD}ms." \
        --arg actual "$(count "${slow}") target server(s) above the threshold: $(names "${slow}")." \
        --arg next_steps "Investigate each listed upstream backend for capacity, connection pooling and timeouts, and confirm it is not the source of the proxy-level latency reported by the latency check." \
        '{title:$title,details:$details,severity:($severity|tonumber),expected:$expected,actual:$actual,next_steps:$next_steps}')
    issues_json=$(echo "${issues_json}" | jq --argjson i "${issue}" '. += [$i]')
fi

echo "${report_json}" > "${REPORT_FILE}"
echo "${issues_json}" > "${ISSUES_FILE}"
echo "Target performance analysis complete. Found $(jq length "${ISSUES_FILE}") issue(s)."
