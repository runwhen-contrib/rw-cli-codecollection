#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Check Cloud Run service memory utilization in a GCP project.
#
# Reads the container memory utilization metric (run.googleapis.com/container/
# memory/utilizations) for each service over the lookback window and flags
# services whose memory utilization meets or exceeds
# MEMORY_UTILIZATION_THRESHOLD, indicating OOM risk / near-limit usage.
#
# REQUIRED ENV VARS:
#   GCP_PROJECT_ID           - GCP project ID
#   RESOURCES                - Comma-separated service names, or "All" (default)
#   METRIC_LOOKBACK_PERIOD   - Lookback window (default 3600s)
#   MEMORY_UTILIZATION_THRESHOLD - High memory utilization percent threshold (default 85)
#
# OUTPUTS:
#   memory_utilization_issues.json - JSON array of issues
# -----------------------------------------------------------------------------
set -euo pipefail
set -x

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
: "${RESOURCES:=All}"
: "${METRIC_LOOKBACK_PERIOD:=3600s}"
: "${MEMORY_UTILIZATION_THRESHOLD:=85}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ISSUES_FILE="memory_utilization_issues.json"
issues_json='[]'

lookback_sec=${METRIC_LOOKBACK_PERIOD%s}
now_epoch=$(date +%s)
start_epoch=$(( now_epoch - lookback_sec ))
START_TIME=$(date -u -d "@$start_epoch" "+%Y-%m-%dT%H:%M:%SZ")
END_TIME=$(date -u -d "@$now_epoch" "+%Y-%m-%dT%H:%M:%SZ")

echo "Checking Cloud Run service memory utilization for project: $GCP_PROJECT_ID (threshold: ${MEMORY_UTILIZATION_THRESHOLD}%, lookback: ${METRIC_LOOKBACK_PERIOD})"

ACCESS_TOKEN=$(gcloud auth print-access-token 2>/dev/null || echo "")
if [ -z "$ACCESS_TOKEN" ]; then
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

source "$SCRIPT_DIR/discover_services.sh"
source "$SCRIPT_DIR/monitoring_query.sh"

threshold=$(echo "$MEMORY_UTILIZATION_THRESHOLD" | awk '{printf "%.0f", $1}')

jq -r '.[].name' "$DISCOVERY_FILE" | while read -r svc; do
  mem_pct=$(query_utilization_pct "run.googleapis.com/container/memory/utilizations" "$svc")
  mem_pct_round=$(echo "$mem_pct" | awk '{printf "%.0f", $1}')

  echo "  Service '$svc': memory utilization ${mem_pct}% (threshold ${threshold}%)"

  if [ "$mem_pct_round" -ge "$threshold" ] 2>/dev/null; then
      issue=$(jq -n \
          --arg title "Cloud Run service \`$svc\` memory utilization is at or above threshold" \
          --arg details "Cloud Run service '$svc' in project '$GCP_PROJECT_ID' reached ${mem_pct}% container memory utilization over the last ${METRIC_LOOKBACK_PERIOD}, at or above the threshold of ${threshold}%. Sustained high memory usage increases the risk of out-of-memory (OOM) restarts and request failures." \
          --arg severity "3" \
          --arg expected "Container memory utilization should remain below ${threshold}%" \
          --arg actual "Cloud Run service '$svc' reached ${mem_pct}% memory utilization" \
          --arg next_steps "Investigate Cloud Run service '$svc'. Increase the memory limit, reduce memory per request, or review whether the memory configuration matches the workload. See: gcloud run services describe $svc --project=$GCP_PROJECT_ID." \
          '{title:$title,details:$details,severity:($severity|tonumber),expected:$expected,actual:$actual,next_steps:$next_steps}')
      issues_json=$(echo "$issues_json" | jq --argjson i "$issue" '. += [$i]')
      echo "$issues_json" > "$ISSUES_FILE"
  fi
done

if [ ! -s "$ISSUES_FILE" ]; then
    echo "[]" > "$ISSUES_FILE"
fi

echo "Memory utilization check complete. Found $(jq length "$ISSUES_FILE") issue(s)."
