#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Shared helper: query Cloud Monitoring time series via the REST API.
#
# NOTE: `gcloud monitoring time-series list` does not exist (the gcloud
# `monitoring` group only covers dashboards/policies/snoozes/uptime), so the
# Monitoring v3 REST API is called directly with a gcloud access token.
#
# Usage:
#   source "$(dirname "$0")/monitoring_query.sh"
#   series=$(query_time_series "$filter" "$start_time" "$end_time")
#
# Prints the `.timeSeries` array (or `[]` on any failure) to stdout.
# -----------------------------------------------------------------------------

query_time_series() {
  local filter="$1" start_time="$2" end_time="$3"
  local token resp

  token=$(gcloud auth print-access-token 2>/dev/null) || { echo "[]"; return 0; }

  resp=$(curl -s -G "https://monitoring.googleapis.com/v3/projects/${GCP_PROJECT_ID}/timeSeries" \
    -H "Authorization: Bearer ${token}" \
    --data-urlencode "filter=${filter}" \
    --data-urlencode "interval.startTime=${start_time}" \
    --data-urlencode "interval.endTime=${end_time}" 2>/dev/null) || { echo "[]"; return 0; }

  # On API errors the response is an error object without .timeSeries.
  echo "$resp" | jq '.timeSeries // []' 2>/dev/null || echo "[]"
}
