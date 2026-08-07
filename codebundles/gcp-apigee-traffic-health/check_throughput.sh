#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Check Apigee Throughput and Anomalies
#
# Reviews request/response volume and the environment/anomaly_count metric,
# flagging anomalous traffic (spikes or drops) that may indicate an incident,
# a mis-route, or a dead backend.
#
# REQUIRED ENV VARS:
#   GCP_PROJECT_ID            - GCP project hosting the Apigee runtime
#   METRIC_WINDOW_MIN         - Lookback window in minutes (default 60)
#
# OPTIONAL ENV VARS:
#   MOCK_DATA_FILE            - Path to mock throughput data (deterministic tests)
#   THROUGHPUT_DEVIATION_PCT  - Percent deviation considered a spike/drop (default 200)
#   APIGEE_SCOPE_FILE         - Path to scope JSON (default apigee_scope.json)
#
# OUTPUTS:
#   throughput_issues.json   - JSON array of issues
#   throughput_report.json   - Per-environment throughput + anomaly summary
# -----------------------------------------------------------------------------
set -euo pipefail
set -x

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
: "${METRIC_WINDOW_MIN:=60}"
: "${THROUGHPUT_DEVIATION_PCT:=200}"
: "${APIGEE_SCOPE_FILE:=apigee_scope.json}"

ISSUES_FILE="throughput_issues.json"
REPORT_FILE="throughput_report.json"
issues_json='[]'

window_seconds=$(( METRIC_WINDOW_MIN * 60 ))
now_epoch=$(date +%s)
start_epoch=$(( now_epoch - window_seconds ))
start_time=$(date -u -d "@$start_epoch" "+%Y-%m-%dT%H:%M:%SZ")
end_time=$(date -u -d "@$now_epoch" "+%Y-%m-%dT%H:%M:%SZ")

echo "Analyzing Apigee throughput and anomalies for project: $GCP_PROJECT_ID (window: ${METRIC_WINDOW_MIN}m)"

# ---------------------------------------------------------------------------
# Mock path (deterministic tests)
# Expected format: array of {"environment","total_requests","previous_total_requests","anomaly_count"}
# ---------------------------------------------------------------------------
if [ -n "${MOCK_DATA_FILE:-}" ] && [ -f "$MOCK_DATA_FILE" ]; then
    echo "Using mock throughput data from $MOCK_DATA_FILE"
    report_json='[]'
    while IFS= read -r row; do
        [ -z "$row" ] && continue
        environment=$(echo "$row" | jq -r '.environment')
        total=$(echo "$row" | jq -r '.total_requests // 0')
        previous=$(echo "$row" | jq -r '.previous_total_requests // 0')
        anomaly_count=$(echo "$row" | jq -r '.anomaly_count // 0')
        deviation=0
        if [ "${previous:-0}" -gt 0 ]; then
            deviation=$(awk -v c="$total" -v p="$previous" 'BEGIN { if (p==0) print 0; else print ((c-p)/p)*100 }')
            deviation=$(printf "%.0f" "$deviation")
        fi
        echo "  environment '$environment': total=$total previous=$previous deviation=${deviation}% anomaly_count=$anomaly_count"
        report_json=$(echo "$report_json" | jq \
            --arg environment "$environment" --arg total "$total" --arg deviation "$deviation" --arg anomaly "$anomaly_count" \
            '. += [{"environment":$environment,"total_requests":($total|tonumber),"deviation_percent":($deviation|tonumber),"anomaly_count":($anomaly|tonumber)}]')
        abs_dev=$(awk -v d="$deviation" 'BEGIN{ if (d<0) print -d; else print d }')
        spike_drop=$(awk -v d="$abs_dev" -v th="$THROUGHPUT_DEVIATION_PCT" 'BEGIN { print (d > th) ? "1" : "0" }')
        if [ "${anomaly_count:-0}" -gt 0 ] || [ "$spike_drop" = "1" ]; then
            if [ "${anomaly_count:-0}" -gt 0 ]; then
                sev=2
                what="Apigee detected $anomaly_count anomaly/anomalies for environment '$environment'"
                steps="Review the Apigee anomaly details in Cloud Monitoring; investigate spikes/drops in API calls that may indicate an incident, a mis-route, or a dead backend."
            else
                sev=2
                what="Throughput for environment '$environment' deviated by ${deviation}% (threshold ${THROUGHPUT_DEVIATION_PCT}%) in the last ${METRIC_WINDOW_MIN}m"
                steps="Investigate the traffic change; check whether it reflects an expected launch/event or signals an incident, mis-route, or dead backend."
            fi
            issue=$(jq -n \
                --arg title "Apigee throughput anomaly for environment \`$environment\`" \
                --arg details "$what. Current requests: $total, previous: $previous, anomaly_count: $anomaly_count in project '$GCP_PROJECT_ID'." \
                --arg severity "$sev" \
                --arg expected "Apigee environment throughput should be stable with no anomalies detected" \
                --arg actual "$what" \
                --arg next_steps "$steps" \
                '{title:$title,details:$details,severity:($severity|tonumber),expected:$expected,actual:$actual,next_steps:$next_steps}')
            issues_json=$(echo "$issues_json" | jq --argjson i "$issue" '. += [$i]')
        fi
    done < <(jq -c '.[]' "$MOCK_DATA_FILE")
    echo "$report_json" > "$REPORT_FILE"
    echo "$issues_json" > "$ISSUES_FILE"
    echo "Throughput analysis complete (mock). Found $(jq length "$ISSUES_FILE") issue(s)."
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

query_metric_total() {
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
    environments=$(jq -r '.environments[]' "$APIGEE_SCOPE_FILE" 2>/dev/null || true)
else
    environments=""
fi
if [ -z "$environments" ]; then
    echo "No environments to evaluate (scope empty or not found)."
    echo "[]" > "$REPORT_FILE"
    echo "[]" > "$ISSUES_FILE"
    exit 0
fi

report_json='[]'
while IFS= read -r environment; do
    [ -z "$environment" ] && continue
    filter="metric.label.environment=\"$environment\""
    total=$(query_metric_total "apigee.googleapis.com/environment/api_call_count" "$filter")
    anomaly=$(query_metric_total "apigee.googleapis.com/environment/anomaly_count" "$filter")
    total=$(echo "$total" | awk '{printf "%.0f", $1}')
    anomaly=$(echo "$anomaly" | awk '{printf "%.0f", $1}')
    echo "  environment '$environment': total=$total anomaly_count=$anomaly"
    report_json=$(echo "$report_json" | jq \
        --arg environment "$environment" --arg total "$total" --arg anomaly "$anomaly" \
        '. += [{"environment":$environment,"total_requests":($total|tonumber),"anomaly_count":($anomaly|tonumber)}]')
    if [ "$anomaly" -gt 0 ]; then
        issue=$(jq -n \
            --arg title "Apigee detected anomalies for environment \`$environment\`" \
            --arg details "Apigee detected $anomaly anomaly/anomalies for environment '$environment' in project '$GCP_PROJECT_ID' over the last ${METRIC_WINDOW_MIN}m." \
            --arg severity "2" \
            --arg expected "Apigee environment should have no detected anomalies" \
            --arg actual "Apigee detected $anomaly anomaly/anomalies for environment '$environment'" \
            --arg next_steps "Review the Apigee anomaly details in Cloud Monitoring; investigate spikes/drops in API calls that may indicate an incident, a mis-route, or a dead backend." \
            '{title:$title,details:$details,severity:($severity|tonumber),expected:$expected,actual:$actual,next_steps:$next_steps}')
        issues_json=$(echo "$issues_json" | jq --argjson i "$issue" '. += [$i]')
    fi
done <<< "$environments"

echo "$report_json" > "$REPORT_FILE"
echo "$issues_json" > "$ISSUES_FILE"
echo "Throughput analysis complete. Found $(jq length "$ISSUES_FILE") issue(s)."
