#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Shared helper for querying Cloud Run utilization metrics from Cloud Monitoring.
#
# This file is meant to be `source`d by the utilization check scripts. It
# requires the following to already be set in the sourcing script:
#   GCP_PROJECT_ID      - GCP project ID
#   START_TIME / END_TIME - RFC3339 interval bounds covered by the lookback
#   ACCESS_TOKEN        - OAuth access token (gcloud auth print-access-token)
#   METRIC_LOOKBACK     - human readable lookback string for messages (e.g. 3600s)
#
# Provides:
#   query_utilization_pct <metric_type> <service_name>
#     Fetches the Cloud Run utilization metric for a service and prints the
#     maximum utilization over the lookback window as a percentage (0-100).
# -----------------------------------------------------------------------------
set -euo pipefail

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
: "${START_TIME:?Must set START_TIME}"
: "${END_TIME:?Must set END_TIME}"
: "${ACCESS_TOKEN:?Must set ACCESS_TOKEN}"

query_utilization_pct() {
    local metric_type="$1"
    local service_name="$2"
    local filter="metric.type=\"$metric_type\" AND resource.type=\"cloud_run_revision\" AND resource.labels.service_name=\"$service_name\""
    local encoded
    encoded=$(jq -rn --arg v "$filter" '$v|@uri')
    local url="https://monitoring.googleapis.com/v3/projects/$GCP_PROJECT_ID/timeSeries?filter=$encoded&interval.startTime=$START_TIME&interval.endTime=$END_TIME&aggregation.alignmentPeriod=60s&aggregation.perSeriesAligner=ALIGN_MEAN&aggregation.crossSeriesReducer=REDUCE_MEAN&view=FULL"
    local resp
    resp=$(curl -s -H "Authorization: Bearer $ACCESS_TOKEN" "$url" 2>/dev/null || echo "{}")
    # Utilization is reported as a fraction of the allocated resource (0-1);
    # report the max across the lookback window as a percentage (0-100).
    local max_frac
    max_frac=$(echo "$resp" | jq '[.timeSeries[].points[].value.doubleValue // 0] | max // 0' 2>/dev/null || echo "0")
    echo "$max_frac" | awk '{printf "%.1f", $1 * 100}'
}
