#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Check Apigee API Error and Fault Rates
#
# Queries proxy-level proxyv2 request/response counts and server fault_count
# metrics over the window to compute error/fault rates, flagging proxies whose
# 4xx/5xx or fault rate exceeds ERROR_RATE_THRESHOLD (percent).
#
# REQUIRED ENV VARS:
#   GCP_PROJECT_ID            - GCP project hosting the Apigee runtime
#   ERROR_RATE_THRESHOLD      - Max error/fault rate in percent (default 5)
#   METRIC_WINDOW_MIN         - Lookback window in minutes (default 60)
#
# OPTIONAL ENV VARS:
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
: "${ERROR_RATE_THRESHOLD:=5}"
: "${METRIC_WINDOW_MIN:=60}"
: "${APIGEE_SCOPE_FILE:=apigee_scope.json}"

ISSUES_FILE="error_rate_issues.json"
REPORT_FILE="error_rate_report.json"
issues_json='[]'

window_seconds=$(( METRIC_WINDOW_MIN * 60 ))
now_epoch=$(date +%s)
start_epoch=$(( now_epoch - window_seconds ))
start_time=$(date -u -d "@$start_epoch" "+%Y-%m-%dT%H:%M:%SZ")
end_time=$(date -u -d "@$now_epoch" "+%Y-%m-%dT%H:%M:%SZ")

echo "Analyzing Apigee error/fault rates for project: $GCP_PROJECT_ID (threshold: ${ERROR_RATE_THRESHOLD}%, window: ${METRIC_WINDOW_MIN}m)"

# ---------------------------------------------------------------------------
# Mock path (deterministic tests)
# Expected format: array of {"proxy","total_requests","errors_4xx","errors_5xx","faults"}
# ---------------------------------------------------------------------------
if [ -n "${MOCK_DATA_FILE:-}" ] && [ -f "$MOCK_DATA_FILE" ]; then
    echo "Using mock error rate data from $MOCK_DATA_FILE"
    report_json='[]'
    while IFS= read -r row; do
        [ -z "$row" ] && continue
        proxy=$(echo "$row" | jq -r '.proxy')
        total=$(echo "$row" | jq -r '.total_requests // 0')
        e4=$(echo "$row" | jq -r '.errors_4xx // 0')
        e5=$(echo "$row" | jq -r '.errors_5xx // 0')
        faults=$(echo "$row" | jq -r '.faults // 0')
        err=$(( e4 + e5 + faults ))
        if [ "${total:-0}" -le 0 ]; then
            rate=0
        else
            rate=$(awk -v e="$err" -v t="$total" 'BEGIN { printf "%.2f", (e*100)/t }')
        fi
        echo "  proxy '$proxy': errors=$err total=$total rate=${rate}%"
        report_json=$(echo "$report_json" | jq \
            --arg proxy "$proxy" --arg rate "$rate" --arg err "$err" --arg total "$total" --arg e5 "$e5" --arg faults "$faults" \
            '. += [{"proxy":$proxy,"error_rate_percent":($rate|tonumber),"error_count":($err|tonumber),"total_requests":($total|tonumber) ,"errors_5xx":($e5|tonumber),"faults":($faults|tonumber)}]')
        flag=$(awk -v r="$rate" -v thr="$ERROR_RATE_THRESHOLD" 'BEGIN { print (r > thr) ? "1" : "0" }')
        if [ "$flag" = "1" ]; then
            issue=$(jq -n \
                --arg title "Apigee proxy \`$proxy\` has a high error/fault rate" \
                --arg details "Apigee proxy '$proxy' in project '$GCP_PROJECT_ID' produced $err errors ($e5 5xx responses, $faults faults) out of $total requests in the last ${METRIC_WINDOW_MIN}m (${rate}%, threshold $ERROR_RATE_THRESHOLD%)." \
                --arg severity "3" \
                --arg expected "Apigee proxy error/fault rate should remain below $ERROR_RATE_THRESHOLD%" \
                --arg actual "Apigee proxy '$proxy' has an error/fault rate of ${rate}%" \
                --arg next_steps "Investigate elevated 4xx/5xx responses and faults. Check the proxy for policy errors, backend misconfiguration, or recent revisions. Review the proxy in Cloud Monitoring to confirm response code distribution." \
                '{title:$title,details:$details,severity:($severity|tonumber),expected:$expected,actual:$actual,next_steps:$next_steps}')
            issues_json=$(echo "$issues_json" | jq --argjson i "$issue" '. += [$i]')
        fi
    done < <(jq -c '.[]' "$MOCK_DATA_FILE")
    echo "$report_json" > "$REPORT_FILE"
    echo "$issues_json" > "$ISSUES_FILE"
    echo "Error rate analysis complete (mock). Found $(jq length "$ISSUES_FILE") issue(s)."
    exit 0
fi

# ---------------------------------------------------------------------------
# Live path: Cloud Monitoring
# ---------------------------------------------------------------------------
access_token=$(gcloud auth print-access-token 2>/dev/null || echo "")
if [ -z "$access_token" ]; then
    issues_json=$(echo "$issues_json" | jq \
        --arg title "Cannot authenticate to Cloud Monitoring for project \`$GCP_PROJECT_ID\`" \
        --arg details "Unable to obtain an access token via gcloud for the Cloud Monitoring API." \
        --arg severity "4" \
        --arg expected "Cloud Monitoring metrics should be retrievable" \
        --arg actual "Could not obtain access token" \
        --arg next_steps "Ensure the service account has roles/monitoring.viewer and is properly authenticated." \
        '. += [{"title":$title,"details":$details,"severity":($severity|tonumber),"expected":$expected,"actual":$actual,"next_steps":$next_steps}]')
    echo "$issues_json" > "$ISSUES_FILE"
    echo "[]" > "$REPORT_FILE"
    exit 0
fi

# Helper: query a metric and return the summed count.
query_metric_count() {
    local metric_type="$1"
    local extra_filter="$2"
    local filter="metric.type=\"$metric_type\""
    if [ -n "$extra_filter" ]; then
        filter="$filter AND $extra_filter"
    fi
    local encoded
    encoded=$(jq -rn --arg v "$filter" '$v|@uri')
    local url="https://monitoring.googleapis.com/v3/projects/$GCP_PROJECT_ID/timeSeries?filter=$encoded&interval.startTime=$start_time&interval.endTime=$end_time&aggregation.alignmentPeriod=60s&aggregation.perSeriesAligner=ALIGN_SUM&aggregation.crossSeriesReducer=REDUCE_SUM&view=FULL"
    local resp
    resp=$(curl -s -H "Authorization: Bearer $access_token" "$url" 2>/dev/null || echo "{}")
    echo "$resp" | jq '[.timeSeries[].points[].value | (.int64Value // .doubleValue // 0) | tonumber] | add // 0' 2>/dev/null || echo "0"
}

if [ -f "$APIGEE_SCOPE_FILE" ]; then
    proxies=$(jq -r '.proxies[]' "$APIGEE_SCOPE_FILE" 2>/dev/null || true)
else
    proxies=""
fi
if [ -z "$proxies" ]; then
    echo "No proxies to evaluate (scope empty or not found)."
    echo "[]" > "$REPORT_FILE"
    echo "[]" > "$ISSUES_FILE"
    exit 0
fi

report_json='[]'
while IFS= read -r proxy; do
    [ -z "$proxy" ] && continue
    filter="metric.label.proxy=\"$proxy\""
    total=$(query_metric_count "apigee.googleapis.com/proxyv2/request_count" "$filter")
    e5=$(query_metric_count "apigee.googleapis.com/proxyv2/request_count" "$filter AND metric.label.response_code_class=\"5xx\"")
    faults=$(query_metric_count "apigee.googleapis.com/server/fault_count" "$filter")
    total=$(echo "$total" | awk '{printf "%.0f", $1}')
    e5=$(echo "$e5" | awk '{printf "%.0f", $1}')
    faults=$(echo "$faults" | awk '{printf "%.0f", $1}')
    err=$(( e5 + faults ))
    if [ "$total" -le 0 ]; then
        rate=0
    else
        rate=$(awk -v e="$err" -v t="$total" 'BEGIN { printf "%.2f", (e*100)/t }')
    fi
    echo "  proxy '$proxy': 5xx=$e5 faults=$faults total=$total rate=${rate}%"
    report_json=$(echo "$report_json" | jq \
        --arg proxy "$proxy" --arg rate "$rate" --arg err "$err" --arg total "$total" \
        '. += [{"proxy":$proxy,"error_rate_percent":($rate|tonumber),"error_count":($err|tonumber),"total_requests":($total|tonumber)}]')
    flag=$(awk -v r="$rate" -v thr="$ERROR_RATE_THRESHOLD" 'BEGIN { print (r > thr) ? "1" : "0" }')
    if [ "$flag" = "1" ]; then
        issue=$(jq -n \
            --arg title "Apigee proxy \`$proxy\` has a high error/fault rate" \
            --arg details "Apigee proxy '$proxy' in project '$GCP_PROJECT_ID' produced $err errors ($e5 5xx responses, $faults faults) out of $total requests in the last ${METRIC_WINDOW_MIN}m (${rate}%, threshold $ERROR_RATE_THRESHOLD%)." \
            --arg severity "3" \
            --arg expected "Apigee proxy error/fault rate should remain below $ERROR_RATE_THRESHOLD%" \
            --arg actual "Apigee proxy '$proxy' has an error/fault rate of ${rate}%" \
            --arg next_steps "Investigate elevated 4xx/5xx responses and faults. Check the proxy for policy errors, backend misconfiguration, or recent revisions." \
            '{title:$title,details:$details,severity:($severity|tonumber),expected:$expected,actual:$actual,next_steps:$next_steps}')
        issues_json=$(echo "$issues_json" | jq --argjson i "$issue" '. += [$i]')
    fi
done <<< "$proxies"

echo "$report_json" > "$REPORT_FILE"
echo "$issues_json" > "$ISSUES_FILE"
echo "Error rate analysis complete. Found $(jq length "$ISSUES_FILE") issue(s)."
