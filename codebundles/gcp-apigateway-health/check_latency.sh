#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Analyze GCP API Gateway Latency
#
# Queries Cloud Monitoring for p95 gateway latency, flagging values above
# LATENCY_THRESHOLD_MS (degradation, sev 3), and checks the gap between total
# gateway latency and backend latency; a large gap isolates gateway (ESPv2)
# overhead from a merely slow backend.
#
# Metric types resolved at runtime via apigateway_common.sh with overrides.
#
# REQUIRED ENV VARS:
#   GCP_PROJECT_ID
#   LATENCY_THRESHOLD_MS (default 5000)
#   LATENCY_GAP_THRESHOLD_MS (default 1000)
#   METRIC_LOOKBACK_PERIOD (default 3600s)
#
# OUTPUTS:
#   latency_issues.json
# -----------------------------------------------------------------------------
set -euo pipefail
set -x

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
: "${LATENCY_THRESHOLD_MS:=5000}"
: "${LATENCY_GAP_THRESHOLD_MS:=1000}"
: "${METRIC_LOOKBACK_PERIOD:=3600s}"
. ./apigateway_common.sh

ISSUES_FILE="latency_issues.json"
issues='[]'
lookback=${METRIC_LOOKBACK_PERIOD%s}
now_epoch=$(date +%s)
start_epoch=$(( now_epoch - lookback ))
start_time=$(apigw_epoch_to_iso8601 "$start_epoch")
end_time=$(apigw_epoch_to_iso8601 "$now_epoch")

echo "Analyzing gateway latency for project: $GCP_PROJECT_ID (p95 threshold: ${LATENCY_THRESHOLD_MS}ms, gap threshold: ${LATENCY_GAP_THRESHOLD_MS}ms)"

access_token=$(apigw_get_access_token)
if [ -z "$access_token" ]; then
    issues=$(echo "$issues" | jq \
        --arg title "Cannot authenticate to Cloud Monitoring for project \`$GCP_PROJECT_ID\`" \
        --arg details "Unable to obtain an access token via gcloud for the Cloud Monitoring API." \
        --arg severity "3" \
        --arg expected "Cloud Monitoring metrics should be retrievable" \
        --arg actual "Could not obtain access token" \
        --arg next_steps "Ensure the service account has roles/monitoring.viewer and is properly authenticated." \
        '. += [{"title":$title,"details":$details,"severity":($severity|tonumber),"expected":$expected,"actual":$actual,"next_steps":$next_steps}]')
    apigw_write_issues "$ISSUES_FILE" "$issues"
    exit 0
fi

total_metric=$(apigw_resolve_latency_metric)
backend_metric=$(apigw_resolve_backend_latency_metric)

query_p95_ms() {
    local metric_type="$1"
    local filter="metric.type=\"$metric_type\""
    local encoded
    encoded=$(jq -rn --arg v "$filter" '$v|@uri')
    local url="https://monitoring.googleapis.com/v3/projects/$GCP_PROJECT_ID/timeSeries?filter=$encoded&interval.startTime=$start_time&interval.endTime=$end_time&aggregation.alignmentPeriod=60s&aggregation.perSeriesAligner=ALIGN_PERCENTILE_95&aggregation.crossSeriesReducer=REDUCE_PERCENTILE_95&view=FULL"
    local resp
    resp=$(curl -s -H "Authorization: Bearer $access_token" "$url" 2>/dev/null || echo "{}")
    echo "$resp" | jq '[.timeSeries[].points[].value.doubleValue | tonumber] | max // 0 | . * 1000' 2>/dev/null || echo "0"
}

total_p95=$(query_p95_ms "$total_metric")
total_p95=$(echo "$total_p95" | awk '{printf "%.0f", $1}')

if [ "$total_p95" = "0" ]; then
    echo "  No latency data available for metric $total_metric in lookback window."
else
    echo "  Total gateway p95 latency: ${total_p95}ms (metric $total_metric)"
    if [ "$total_p95" -gt "$LATENCY_THRESHOLD_MS" ]; then
        issue=$(jq -n \
            --arg title "API Gateway has high p95 latency" \
            --arg details "API Gateway in project '$GCP_PROJECT_ID' has a p95 latency of ${total_p95}ms in the last ${METRIC_LOOKBACK_PERIOD}, exceeding the threshold of ${LATENCY_THRESHOLD_MS}ms. This indicates end-to-end request degradation." \
            --arg severity "3" \
            --arg expected "Gateway p95 latency should remain below ${LATENCY_THRESHOLD_MS}ms" \
            --arg actual "Gateway p95 latency is ${total_p95}ms" \
            --arg next_steps "Investigate latency: distinguish backend slowness from gateway overhead using the latency gap check; review Cloud Run scaling and backend cold starts. Hand off backend-internal evidence to the gcp-cloudrun-service-health bundle." \
            '{title:$title,details:$details,severity:($severity|tonumber),expected:$expected,actual:$actual,next_steps:$next_steps}')
        issues=$(echo "$issues" | jq --argjson i "$issue" '. += [$i]')
    fi

    backend_p95=$(query_p95_ms "$backend_metric")
    backend_p95=$(echo "$backend_p95" | awk '{printf "%.0f", $1}')
    if [ "$backend_p95" != "0" ]; then
        gap=$(( total_p95 - backend_p95 ))
        echo "  Backend p95 latency: ${backend_p95}ms, gateway-vs-backend gap: ${gap}ms"
        if [ "$gap" -gt "$LATENCY_GAP_THRESHOLD_MS" ]; then
            issue=$(jq -n \
                --arg title "API Gateway (ESPv2) overhead latency is high" \
                --arg details "In project '$GCP_PROJECT_ID' the p95 latency gap between total gateway latency (${total_p95}ms) and backend latency (${backend_p95}ms) is ${gap}ms, exceeding the threshold of ${LATENCY_GAP_THRESHOLD_MS}ms. A large gap isolates gateway/ESPv2 overhead as the source of slow responses rather than a slow backend." \
                --arg severity "3" \
                --arg expected "The gateway-vs-backend latency gap should remain below ${LATENCY_GAP_THRESHOLD_MS}ms" \
                --arg actual "Gateway-vs-backend p95 latency gap is ${gap}ms" \
                --arg next_steps "Review ESPv2 configuration, authentication/authorization checks, and any gateway-side middleware that may add latency. If the backend itself is slow, hand off to the gcp-cloudrun-service-health bundle." \
                '{title:$title,details:$details,severity:($severity|tonumber),expected:$expected,actual:$actual,next_steps:$next_steps}')
            issues=$(echo "$issues" | jq --argjson i "$issue" '. += [$i]')
        fi
    fi
fi

apigw_write_issues "$ISSUES_FILE" "$issues"

echo "Latency analysis complete. Found $(jq length "$ISSUES_FILE") issue(s)."
