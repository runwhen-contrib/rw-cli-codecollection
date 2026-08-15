#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Analyze Load Balancer Latency Performance
#
# Queries Cloud Monitoring metrics for request latency (P95) on HTTP/S load
# balancers and flags load balancers whose latency exceeds
# LATENCY_THRESHOLD_MS.
#
# REQUIRED ENV VARS:
#   GCP_PROJECT_ID          - GCP project ID hosting the load balancers
#   LATENCY_THRESHOLD_MS    - Max acceptable P95 latency in ms (default 5000)
#   METRIC_LOOKBACK_PERIOD  - Lookback period in seconds (default 3600s)
#
# OUTPUTS:
#   latency_issues.json     - JSON array of issues
# -----------------------------------------------------------------------------
set -euo pipefail
set -x

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
: "${LATENCY_THRESHOLD_MS:=5000}"
: "${METRIC_LOOKBACK_PERIOD:=3600s}"

ISSUES_FILE="latency_issues.json"
issues_json='[]'
lookback=${METRIC_LOOKBACK_PERIOD%s}
now_epoch=$(date +%s)
start_epoch=$(( now_epoch - lookback ))
start_time=$(date -u -d "@$start_epoch" "+%Y-%m-%dT%H:%M:%SZ")
end_time=$(date -u -d "@$now_epoch" "+%Y-%m-%dT%H:%M:%SZ")

echo "Analyzing latency for project: $GCP_PROJECT_ID (P95 threshold: ${LATENCY_THRESHOLD_MS}ms, lookback: ${METRIC_LOOKBACK_PERIOD})"

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

# Helper: query a distribution metric and return its P95 in milliseconds.
query_metric_p95_ms() {
    local metric_type="$1"
    local extra_filter="$2"
    local filter="metric.type=\"$metric_type\" AND $extra_filter"
    local encoded
    encoded=$(jq -rn --arg v "$filter" '$v|@uri')
    local url="https://monitoring.googleapis.com/v3/projects/$GCP_PROJECT_ID/timeSeries?filter=$encoded&interval.startTime=$start_time&interval.endTime=$end_time&aggregation.alignmentPeriod=60s&aggregation.perSeriesAligner=ALIGN_PERCENTILE_95&aggregation.crossSeriesReducer=REDUCE_PERCENTILE_95&view=FULL"
    local resp
    resp=$(curl -s -H "Authorization: Bearer $access_token" "$url" 2>/dev/null || echo "{}")
    # Value is in seconds; convert to milliseconds.
    echo "$resp" | jq '[.timeSeries[].points[].value.doubleValue | tonumber] | max // 0 | . * 1000' 2>/dev/null || echo "0"
}

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
            metric="loadbalancing.googleapis.com/https/total_latencies"
        else
            metric="loadbalancing.googleapis.com/http/total_latencies"
        fi
        fwd_filter="resource.labels.forwarding_rule_name=\"$lb_name\""
        p95_ms=$(query_metric_p95_ms "$metric" "$fwd_filter")
    else
        # Non-HTTP LBs: use backend latency metric when available; otherwise skip.
        metric="compute.googleapis.com/backend/request_count"
        fwd_filter="resource.labels.forwarding_rule_name=\"$lb_name\""
        p95_ms=$(query_metric_p95_ms "$metric" "$fwd_filter")
    fi

    p95_ms=$(echo "$p95_ms" | awk '{printf "%.0f", $1}')
    if [ "$p95_ms" = "0" ]; then
        echo "  LB '$lb_name' ($lb_type): no latency data in lookback window."
        continue
    fi

    echo "  LB '$lb_name' ($lb_type): P95 latency ${p95_ms}ms"

    if [ "$p95_ms" -gt "$LATENCY_THRESHOLD_MS" ]; then
        issue=$(jq -n \
            --arg title "Load balancer \`$lb_name\` has high P95 latency" \
            --arg details "Load balancer '$lb_name' ($lb_type) in project '$GCP_PROJECT_ID' has a P95 latency of ${p95_ms}ms in the last ${METRIC_LOOKBACK_PERIOD}, exceeding the threshold of ${LATENCY_THRESHOLD_MS}ms." \
            --arg severity "2" \
            --arg expected "Load balancer P95 latency should remain below ${LATENCY_THRESHOLD_MS}ms" \
            --arg actual "Load balancer '$lb_name' has a P95 latency of ${p95_ms}ms" \
            --arg next_steps "Investigate latency: check backend capacity, autoscaling, and backend health. Review the load balancer metrics in Cloud Monitoring and confirm backend services are not degraded." \
            '{title:$title,details:$details,severity:($severity|tonumber),expected:$expected,actual:$actual,next_steps:$next_steps}')
        issues_json=$(echo "$issues_json" | jq --argjson i "$issue" '. += [$i]')
        echo "$issues_json" > "$ISSUES_FILE"
    fi
done

if [ ! -s "$ISSUES_FILE" ]; then
    echo "[]" > "$ISSUES_FILE"
fi

echo "Latency analysis complete. Found $(jq length "$ISSUES_FILE") issue(s)."
