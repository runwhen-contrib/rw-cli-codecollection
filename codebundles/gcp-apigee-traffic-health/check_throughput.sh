#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Check Apigee Throughput and Anomalies
#
# Reviews request/response volume and the environment/anomaly_count metric,
# raising ONE finding PER FAILURE MODE that lists every affected environment:
#
#   1. Apigee itself reported anomalies (environment/anomaly_count > 0)
#   2. Throughput deviated beyond THROUGHPUT_DEVIATION_PCT versus the previous
#      window (a spike or a drop)
#
# These are separate modes with separate remedies, so they are separate issues.
# Neither title names an environment or a count -- see check_error_rates.sh.
#
# REQUIRED ENV VARS:
#   GCP_PROJECT_ID            - GCP project hosting the Apigee runtime
#
# OPTIONAL ENV VARS:
#   APIGEE_ORG                - Apigee org name; falls back to the org recorded
#                               in the scope file
#   METRIC_WINDOW_MIN         - Lookback window in minutes (default 60)
#   THROUGHPUT_DEVIATION_PCT  - Percent deviation considered a spike/drop (default 200)
#   MOCK_DATA_FILE            - Path to mock throughput data (deterministic tests)
#   APIGEE_SCOPE_FILE         - Path to scope JSON (default apigee_scope.json)
#
# OUTPUTS:
#   throughput_issues.json   - JSON array of issues
#   throughput_report.json   - Per-environment throughput + anomaly summary
# -----------------------------------------------------------------------------
set -euo pipefail
set -x

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
: "${APIGEE_ORG:=}"
: "${METRIC_WINDOW_MIN:=60}"
: "${THROUGHPUT_DEVIATION_PCT:=200}"
: "${APIGEE_SCOPE_FILE:=apigee_scope.json}"

ISSUES_FILE="throughput_issues.json"
REPORT_FILE="throughput_report.json"
issues_json='[]'
report_json='[]'
anomalous=""
deviating=""

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
# Expected format: array of {"environment","total_requests","previous_total_requests","anomaly_count"}
# ---------------------------------------------------------------------------
if [ -n "${MOCK_DATA_FILE:-}" ] && [ -f "${MOCK_DATA_FILE}" ]; then
    [ -z "${APIGEE_ORG}" ] && APIGEE_ORG="mock-org"
    echo "Analyzing Apigee throughput and anomalies for org: ${APIGEE_ORG} (window: ${METRIC_WINDOW_MIN}m)"
    echo "Using mock throughput data from ${MOCK_DATA_FILE}"
    while IFS= read -r row; do
        [ -z "${row}" ] && continue
        environment=$(echo "${row}" | jq -r '.environment')
        total=$(echo "${row}" | jq -r '.total_requests // 0')
        previous=$(echo "${row}" | jq -r '.previous_total_requests // 0')
        anomaly_count=$(echo "${row}" | jq -r '.anomaly_count // 0')
        deviation=0
        if [ "${previous:-0}" -gt 0 ]; then
            deviation=$(awk -v c="${total}" -v p="${previous}" 'BEGIN { if (p==0) print 0; else print ((c-p)/p)*100 }')
            deviation=$(printf "%.0f" "${deviation}")
        fi
        echo "  environment '${environment}': total=${total} previous=${previous} deviation=${deviation}% anomaly_count=${anomaly_count}"
        report_json=$(echo "${report_json}" | jq \
            --arg environment "${environment}" --arg total "${total}" --arg deviation "${deviation}" --arg anomaly "${anomaly_count}" \
            '. += [{"environment":$environment,"total_requests":($total|tonumber),"deviation_percent":($deviation|tonumber),"anomaly_count":($anomaly|tonumber)}]')
        # Compared as a RATIO in both directions, not as a signed percentage.
        # A drop is bounded at -100%, so `abs(deviation) > 200` could only ever
        # fire on a spike: an environment whose traffic fell to ZERO -- the most
        # important throughput signal there is -- scored -100% and was never
        # flagged. Reading the threshold as a factor (200% -> 3x) makes "tripled"
        # and "fell to under a third" both fire, which is what an operator means
        # by a 200% deviation band.
        spike_drop=$(awk -v c="${total}" -v p="${previous}" -v th="${THROUGHPUT_DEVIATION_PCT}" \
            'BEGIN { f = 1 + th/100; print (p > 0 && (c > p*f || c*f < p)) ? "1" : "0" }')
        if [ "${anomaly_count:-0}" -gt 0 ]; then
            anomalous="${anomalous}  - ${environment}: ${anomaly_count} anomaly/anomalies over ${total} requests
"
        fi
        if [ "${spike_drop}" = "1" ]; then
            deviating="${deviating}  - ${environment}: ${deviation}% change (${previous} -> ${total} requests)
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
    echo "Analyzing Apigee throughput and anomalies for org: ${APIGEE_ORG} (window: ${METRIC_WINDOW_MIN}m)"

    access_token=$(gcloud auth print-access-token 2>/dev/null || echo "")
    if [ -z "${access_token}" ]; then
        issues_json=$(echo "${issues_json}" | jq \
            --arg title "Cannot query Cloud Monitoring for Apigee throughput in org \`${APIGEE_ORG}\`" \
            --arg details "Unable to obtain an access token via gcloud for the Cloud Monitoring API in project ${GCP_PROJECT_ID}. No environment was evaluated, so this run determined nothing about throughput." \
            --arg severity "4" \
            --arg expected "Cloud Monitoring metrics should be retrievable." \
            --arg actual "Could not obtain an access token, so no environment was evaluated." \
            --arg next_steps "Ensure the service account has roles/monitoring.viewer and that Suite Initialization's token probe passed." \
            '. += [{"title":$title,"details":$details,"severity":($severity|tonumber),"expected":$expected,"actual":$actual,"next_steps":$next_steps}]')
        echo "${issues_json}" > "${ISSUES_FILE}"
        echo "[]" > "${REPORT_FILE}"
        exit 0
    fi

    query_metric_total() {
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

    environments=$(jq -r '.environments[]?' "${APIGEE_SCOPE_FILE}" 2>/dev/null || true)
    if [ -z "${environments}" ]; then
        # Positive determination of absence -- not a finding.
        echo "Org '${APIGEE_ORG}' has no environments; nothing to evaluate."
        echo "[]" > "${REPORT_FILE}"
        echo "[]" > "${ISSUES_FILE}"
        exit 0
    fi

    while IFS= read -r environment; do
        [ -z "${environment}" ] && continue
        filter="metric.label.environment=\"${environment}\""
        total=$(query_metric_total "apigee.googleapis.com/environment/api_call_count" "${filter}")
        anomaly=$(query_metric_total "apigee.googleapis.com/environment/anomaly_count" "${filter}")
        total=$(echo "${total}" | awk '{printf "%.0f", $1}')
        anomaly=$(echo "${anomaly}" | awk '{printf "%.0f", $1}')
        echo "  environment '${environment}': total=${total} anomaly_count=${anomaly}"
        report_json=$(echo "${report_json}" | jq \
            --arg environment "${environment}" --arg total "${total}" --arg anomaly "${anomaly}" \
            '. += [{"environment":$environment,"total_requests":($total|tonumber),"anomaly_count":($anomaly|tonumber)}]')
        if [ "${anomaly}" -gt 0 ]; then
            anomalous="${anomalous}  - ${environment}: ${anomaly} anomaly/anomalies over ${total} requests
"
        fi
    done <<< "${environments}"
fi

# ---------------------------------------------------------------------------
# One finding per failure mode, listing every affected environment.
# ---------------------------------------------------------------------------
names() { printf '%s' "$1" | sed 's/^  - //; s/:.*//' | tr '\n' ',' | sed 's/,$//; s/,/, /g'; }
count() { printf '%s' "$1" | grep -c . ; }

if [ -n "${anomalous}" ]; then
    issue=$(jq -n \
        --arg title "Apigee reported traffic anomalies in org \`${APIGEE_ORG}\`" \
        --arg details "Apigee's own anomaly detection flagged traffic in the following environment(s) of org ${APIGEE_ORG} (project ${GCP_PROJECT_ID}) over the last ${METRIC_WINDOW_MIN}m:
${anomalous}
An anomaly may indicate an incident, a mis-route, or a dead backend." \
        --arg severity "2" \
        --arg expected "Apigee should detect no traffic anomalies in any environment." \
        --arg actual "$(count "${anomalous}") environment(s) with detected anomalies: $(names "${anomalous}")." \
        --arg next_steps "Review the Apigee anomaly details in Cloud Monitoring for each listed environment, and correlate the spike or drop in API calls with deploys, incidents, and backend health." \
        '{title:$title,details:$details,severity:($severity|tonumber),expected:$expected,actual:$actual,next_steps:$next_steps}')
    issues_json=$(echo "${issues_json}" | jq --argjson i "${issue}" '. += [$i]')
fi

if [ -n "${deviating}" ]; then
    issue=$(jq -n \
        --arg title "Apigee throughput changed sharply in org \`${APIGEE_ORG}\`" \
        --arg details "Request volume in the following environment(s) of org ${APIGEE_ORG} (project ${GCP_PROJECT_ID}) deviated by more than ${THROUGHPUT_DEVIATION_PCT}% from the previous window:
${deviating}
A sharp drop usually means callers can no longer reach the gateway; a sharp spike may be a launch, a retry storm, or abuse." \
        --arg severity "2" \
        --arg expected "Environment request volume should stay within ${THROUGHPUT_DEVIATION_PCT}% of the previous window." \
        --arg actual "$(count "${deviating}") environment(s) outside the deviation band: $(names "${deviating}")." \
        --arg next_steps "Confirm whether the change reflects an expected launch or event. If not, check environment group hostname routing, upstream callers, and backend health for each listed environment." \
        '{title:$title,details:$details,severity:($severity|tonumber),expected:$expected,actual:$actual,next_steps:$next_steps}')
    issues_json=$(echo "${issues_json}" | jq --argjson i "${issue}" '. += [$i]')
fi

echo "${report_json}" > "${REPORT_FILE}"
echo "${issues_json}" > "${ISSUES_FILE}"
echo "Throughput analysis complete. Found $(jq length "${ISSUES_FILE}") issue(s)."
