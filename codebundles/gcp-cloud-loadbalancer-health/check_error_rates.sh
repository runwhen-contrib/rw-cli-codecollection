#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Analyze Load Balancer Error Rates via Cloud Monitoring
#
# Queries Cloud Monitoring metrics for HTTP/S load balancer 5xx error ratios
# and non-HTTP LB error rates over the lookback period, flagging load
# balancers whose error rate exceeds ERROR_RATE_THRESHOLD.
#
# REQUIRED ENV VARS:
#   GCP_PROJECT_ID          - GCP project ID hosting the load balancers
#   ERROR_RATE_THRESHOLD    - Max acceptable 5xx ratio (default 0.01)
#   METRIC_LOOKBACK_PERIOD  - Lookback period in seconds (default 3600s)
#
# OUTPUTS:
#   error_rate_issues.json  - JSON array of issues
# -----------------------------------------------------------------------------
set -euo pipefail
set -x

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
: "${ERROR_RATE_THRESHOLD:=0.01}"
: "${METRIC_LOOKBACK_PERIOD:=3600s}"

ISSUES_FILE="error_rate_issues.json"
issues_json='[]'
lookback=${METRIC_LOOKBACK_PERIOD%s}
now_epoch=$(date +%s)
start_epoch=$(( now_epoch - lookback ))
start_time=$(date -u -d "@$start_epoch" "+%Y-%m-%dT%H:%M:%SZ")
end_time=$(date -u -d "@$now_epoch" "+%Y-%m-%dT%H:%M:%SZ")

echo "Analyzing error rates for project: $GCP_PROJECT_ID (threshold: $ERROR_RATE_THRESHOLD, lookback: ${METRIC_LOOKBACK_PERIOD})"

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
    exit 0
fi

# Helper: query a metric and return the total count (sum of int64 values).
query_metric_count() {
    local metric_type="$1"
    local extra_filter="$2"
    local filter="metric.type=\"$metric_type\" AND $extra_filter"
    local encoded
    encoded=$(jq -rn --arg v "$filter" '$v|@uri')
    local url="https://monitoring.googleapis.com/v3/projects/$GCP_PROJECT_ID/timeSeries?filter=$encoded&interval.startTime=$start_time&interval.endTime=$end_time&aggregation.alignmentPeriod=60s&aggregation.perSeriesAligner=ALIGN_SUM&aggregation.crossSeriesReducer=REDUCE_SUM&view=FULL"
    local resp
    resp=$(curl -s -H "Authorization: Bearer $access_token" "$url" 2>/dev/null || echo "{}")
    echo "$resp" | jq '[.timeSeries[].points[].value | (.int64Value // .doubleValue // 0) | tonumber] | add // 0' 2>/dev/null || echo "0"
}

# Use discovery dump if present, otherwise list forwarding rules directly.
if [ -f "lb_config.json" ]; then
    lbs=$(cat lb_config.json)
else
    lbs=$(gcloud compute forwarding-rules list --project="$GCP_PROJECT_ID" --format=json 2>/dev/null || echo "[]")
fi

echo "$lbs" | jq -c '.[]' 2>/dev/null | while read -r lb; do
    lb_name=$(echo "$lb" | jq -r '.name')
    lb_type=$(echo "$lb" | jq -r '.type')

    if [ "$lb_type" = "HTTP" ] || [ "$lb_type" = "HTTPS" ]; then
        if [ "$lb_type" = "HTTPS" ]; then
            metric="loadbalancing.googleapis.com/https/request_count"
        else
            metric="loadbalancing.googleapis.com/http/request_count"
        fi
        fwd_filter="resource.labels.forwarding_rule_name=\"$lb_name\""
    else
        metric="compute.googleapis.com/backend/request_count"
        fwd_filter="resource.labels.forwarding_rule_name=\"$lb_name\""
    fi

    total=$(query_metric_count "$metric" "$fwd_filter")
    error=$(query_metric_count "$metric" "$fwd_filter AND metric.label.response_code_class=\"5xx\"")

    total=$(echo "$total" | awk '{printf "%.0f", $1}')
    error=$(echo "$error" | awk '{printf "%.0f", $1}')

    if [ "$total" = "0" ]; then
        echo "  LB '$lb_name' ($lb_type): no request data in lookback window."
        continue
    fi

    ratio=$(awk -v e="$error" -v t="$total" 'BEGIN { printf "%.4f", e/t }')
    echo "  LB '$lb_name' ($lb_type): 5xx=$error total=$total ratio=$ratio"

    if [ "$(awk -v r="$ratio" -v thr="$ERROR_RATE_THRESHOLD" 'BEGIN { print (r > thr) ? 1 : 0 }')" = "1" ]; then
        issue=$(jq -n \
            --arg title "Load balancer \`$lb_name\` has a high 5xx error rate" \
            --arg details "Load balancer '$lb_name' ($lb_type) in project '$GCP_PROJECT_ID' returned $error 5xx responses out of $total requests in the last ${METRIC_LOOKBACK_PERIOD} (error ratio $ratio, threshold $ERROR_RATE_THRESHOLD)." \
            --arg severity "3" \
            --arg expected "Load balancer error rate should remain below $ERROR_RATE_THRESHOLD" \
            --arg actual "Load balancer '$lb_name' has a 5xx error ratio of $ratio" \
            --arg next_steps "Investigate elevated 5xx errors. Check backend health, application logs, and recent deployments. Billing alerts: see https://console.cloud.google.com/monitoring for the load balancer metrics." \
            '{title:$title,details:$details,severity:($severity|tonumber),expected:$expected,actual:$actual,next_steps:$next_steps}')
        issues_json=$(echo "$issues_json" | jq --argjson i "$issue" '. += [$i]')
        echo "$issues_json" > "$ISSUES_FILE"
    fi
done

if [ ! -s "$ISSUES_FILE" ]; then
    echo "[]" > "$ISSUES_FILE"
fi

echo "Error rate analysis complete. Found $(jq length "$ISSUES_FILE") issue(s)."
