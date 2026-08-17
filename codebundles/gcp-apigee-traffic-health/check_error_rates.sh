#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Check Apigee API Error and Fault Rates
#
# Queries proxy-level proxyv2 request/response counts and server fault_count
# metrics over the window to compute error/fault rates, raising ONE finding that
# lists every proxy whose 5xx or fault rate exceeds ERROR_RATE_THRESHOLD.
#
# Issue titles carry the failure mode and the org, never a proxy name or a
# count: proxies come and go and their numbers change every run, so a per-proxy
# title opens and closes issues on every execution. The names live in
# details/actual, where they belong.
#
# REQUIRED ENV VARS:
#   GCP_PROJECT_ID            - GCP project hosting the Apigee runtime
#
# OPTIONAL ENV VARS:
#   APIGEE_ORG                - Apigee org name; falls back to the org recorded
#                               in the scope file
#   ERROR_RATE_THRESHOLD      - Max error/fault rate in percent (default 5)
#   METRIC_WINDOW_MIN         - Lookback window in minutes (default 60)
#   MOCK_DATA_FILE            - Path to mock error rate data (deterministic tests)
#   APIGEE_SCOPE_FILE         - Path to scope JSON (default apigee_scope.json)
#
# OUTPUTS:
#   error_rate_issues.json   - JSON array of issues
#   error_rate_report.json   - Per-proxy computed error rates
# -----------------------------------------------------------------------------
set -euo pipefail
set -x

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
: "${APIGEE_ORG:=}"
: "${ERROR_RATE_THRESHOLD:=5}"
: "${METRIC_WINDOW_MIN:=60}"
: "${APIGEE_SCOPE_FILE:=apigee_scope.json}"

ISSUES_FILE="error_rate_issues.json"
REPORT_FILE="error_rate_report.json"
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
# Expected format: array of {"proxy","total_requests","errors_4xx","errors_5xx","faults"}
# ---------------------------------------------------------------------------
if [ -n "${MOCK_DATA_FILE:-}" ] && [ -f "${MOCK_DATA_FILE}" ]; then
    [ -z "${APIGEE_ORG}" ] && APIGEE_ORG="mock-org"
    echo "Analyzing Apigee error/fault rates for org: ${APIGEE_ORG} (threshold: ${ERROR_RATE_THRESHOLD}%, window: ${METRIC_WINDOW_MIN}m)"
    echo "Using mock error rate data from ${MOCK_DATA_FILE}"
    while IFS= read -r row; do
        [ -z "${row}" ] && continue
        proxy=$(echo "${row}" | jq -r '.proxy')
        total=$(echo "${row}" | jq -r '.total_requests // 0')
        e4=$(echo "${row}" | jq -r '.errors_4xx // 0')
        e5=$(echo "${row}" | jq -r '.errors_5xx // 0')
        faults=$(echo "${row}" | jq -r '.faults // 0')
        err=$(( e4 + e5 + faults ))
        if [ "${total:-0}" -le 0 ]; then
            rate=0
        else
            rate=$(awk -v e="${err}" -v t="${total}" 'BEGIN { printf "%.2f", (e*100)/t }')
        fi
        echo "  proxy '${proxy}': errors=${err} total=${total} rate=${rate}%"
        report_json=$(echo "${report_json}" | jq \
            --arg proxy "${proxy}" --arg rate "${rate}" --arg err "${err}" --arg total "${total}" --arg e5 "${e5}" --arg faults "${faults}" \
            '. += [{"proxy":$proxy,"error_rate_percent":($rate|tonumber),"error_count":($err|tonumber),"total_requests":($total|tonumber),"errors_5xx":($e5|tonumber),"faults":($faults|tonumber)}]')
        flag=$(awk -v r="${rate}" -v thr="${ERROR_RATE_THRESHOLD}" 'BEGIN { print (r > thr) ? "1" : "0" }')
        if [ "${flag}" = "1" ]; then
            offenders="${offenders}  - ${proxy}: ${rate}% (${err} errors of ${total} requests; ${e5} 5xx, ${faults} faults)
"
        fi
    done < <(jq -c '.[]' "${MOCK_DATA_FILE}")

# ---------------------------------------------------------------------------
# Live path: Cloud Monitoring
# ---------------------------------------------------------------------------
else
    # Suite Initialization runs discovery and fails the suite when it cannot
    # produce a scope, so by the time this runs the file is guaranteed to exist.
    # A missing one means something is genuinely wrong -- treating it as an empty
    # org here would report "no issues found" for a check that never looked at
    # anything, which is exactly how a blind run passes for a healthy one.
    if [ ! -f "${APIGEE_SCOPE_FILE}" ]; then
        echo "ERROR: ${APIGEE_SCOPE_FILE} is missing. Discovery runs in Suite Initialization;" >&2
        echo "       if you are running this script directly, run discover_metrics_scope.sh first." >&2
        exit 1
    fi
    if [ -z "${APIGEE_ORG}" ]; then
        APIGEE_ORG=$(jq -r '.organization // ""' "${APIGEE_SCOPE_FILE}" 2>/dev/null || echo "")
    fi
    echo "Analyzing Apigee error/fault rates for org: ${APIGEE_ORG} (threshold: ${ERROR_RATE_THRESHOLD}%, window: ${METRIC_WINDOW_MIN}m)"

    access_token=$(gcloud auth print-access-token 2>/dev/null || echo "")
    if [ -z "${access_token}" ]; then
        issues_json=$(echo "${issues_json}" | jq \
            --arg title "Cannot query Cloud Monitoring for Apigee error rates in org \`${APIGEE_ORG}\`" \
            --arg details "Unable to obtain an access token via gcloud for the Cloud Monitoring API in project ${GCP_PROJECT_ID}. No proxy was evaluated, so this run determined nothing about error rates." \
            --arg severity "4" \
            --arg expected "Cloud Monitoring metrics should be retrievable." \
            --arg actual "Could not obtain an access token, so no proxy was evaluated." \
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
        resp=$(curl -s -H "Authorization: Bearer ${access_token}" "${url}" 2>/dev/null || echo "{}")
        echo "${resp}" | jq '[.timeSeries[]?.points[]?.value | (.int64Value // .doubleValue // 0) | tonumber] | add // 0' 2>/dev/null || echo "0"
    }

    proxies=$(jq -r '.proxies[]?' "${APIGEE_SCOPE_FILE}" 2>/dev/null || true)
    if [ -z "${proxies}" ]; then
        # A positive determination of absence: discovery succeeded and the org
        # genuinely has no proxies. Not a finding.
        echo "Org '${APIGEE_ORG}' has no API proxies; nothing to evaluate."
        echo "[]" > "${REPORT_FILE}"
        echo "[]" > "${ISSUES_FILE}"
        exit 0
    fi

    while IFS= read -r proxy; do
        [ -z "${proxy}" ] && continue
        filter="metric.label.proxy=\"${proxy}\""
        total=$(query_metric_count "apigee.googleapis.com/proxyv2/request_count" "${filter}")
        e5=$(query_metric_count "apigee.googleapis.com/proxyv2/request_count" "${filter} AND metric.label.response_code_class=\"5xx\"")
        faults=$(query_metric_count "apigee.googleapis.com/server/fault_count" "${filter}")
        total=$(echo "${total}" | awk '{printf "%.0f", $1}')
        e5=$(echo "${e5}" | awk '{printf "%.0f", $1}')
        faults=$(echo "${faults}" | awk '{printf "%.0f", $1}')
        err=$(( e5 + faults ))
        if [ "${total}" -le 0 ]; then
            rate=0
        else
            rate=$(awk -v e="${err}" -v t="${total}" 'BEGIN { printf "%.2f", (e*100)/t }')
        fi
        echo "  proxy '${proxy}': 5xx=${e5} faults=${faults} total=${total} rate=${rate}%"
        report_json=$(echo "${report_json}" | jq \
            --arg proxy "${proxy}" --arg rate "${rate}" --arg err "${err}" --arg total "${total}" \
            '. += [{"proxy":$proxy,"error_rate_percent":($rate|tonumber),"error_count":($err|tonumber),"total_requests":($total|tonumber)}]')
        flag=$(awk -v r="${rate}" -v thr="${ERROR_RATE_THRESHOLD}" 'BEGIN { print (r > thr) ? "1" : "0" }')
        if [ "${flag}" = "1" ]; then
            offenders="${offenders}  - ${proxy}: ${rate}% (${err} errors of ${total} requests; ${e5} 5xx, ${faults} faults)
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
        --arg title "Apigee proxies have a high error/fault rate in org \`${APIGEE_ORG}\`" \
        --arg details "The following API proxy/proxies in org ${APIGEE_ORG} (project ${GCP_PROJECT_ID}) exceeded the ${ERROR_RATE_THRESHOLD}% error/fault rate over the last ${METRIC_WINDOW_MIN}m:
${offenders}
Callers of these proxies are receiving errors." \
        --arg severity "3" \
        --arg expected "Every Apigee proxy's error/fault rate should remain below ${ERROR_RATE_THRESHOLD}%." \
        --arg actual "$(count "${offenders}") proxy/proxies above the threshold: $(names "${offenders}")." \
        --arg next_steps "Investigate elevated 5xx responses and faults on each listed proxy. Check for policy errors, backend misconfiguration, or a recent revision deploy, and review the response code distribution in Cloud Monitoring." \
        '{title:$title,details:$details,severity:($severity|tonumber),expected:$expected,actual:$actual,next_steps:$next_steps}')
    issues_json=$(echo "${issues_json}" | jq --argjson i "${issue}" '. += [$i]')
fi

echo "${report_json}" > "${REPORT_FILE}"
echo "${issues_json}" > "${ISSUES_FILE}"
echo "Error rate analysis complete. Found $(jq length "${ISSUES_FILE}") issue(s)."
