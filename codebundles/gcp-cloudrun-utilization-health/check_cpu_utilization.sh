#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Check Cloud Run service CPU utilization in a GCP project.
#
# Reads the container CPU utilization metric (run.googleapis.com/container/cpu/
# utilizations) for each service over the lookback window and flags services
# whose CPU utilization meets or exceeds CPU_UTILIZATION_THRESHOLD, indicating
# over-utilization / approaching capacity limits.
#
# REQUIRED ENV VARS:
#   GCP_PROJECT_ID           - GCP project ID
#   RESOURCES                - Comma-separated service names, or "All" (default)
#   METRIC_LOOKBACK_PERIOD   - Lookback window (default 3600s)
#   CPU_UTILIZATION_THRESHOLD- High CPU utilization percent threshold (default 80)
#
# OUTPUTS:
#   cpu_utilization_issues.json - JSON array of issues
# -----------------------------------------------------------------------------
set -euo pipefail
set -x

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
: "${RESOURCES:=All}"
: "${METRIC_LOOKBACK_PERIOD:=3600s}"
: "${CPU_UTILIZATION_THRESHOLD:=80}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ISSUES_FILE="cpu_utilization_issues.json"
issues_json='[]'

lookback_sec=${METRIC_LOOKBACK_PERIOD%s}
now_epoch=$(date +%s)
start_epoch=$(( now_epoch - lookback_sec ))
START_TIME=$(date -u -d "@$start_epoch" "+%Y-%m-%dT%H:%M:%SZ")
END_TIME=$(date -u -d "@$now_epoch" "+%Y-%m-%dT%H:%M:%SZ")

echo "Checking Cloud Run service CPU utilization for project: $GCP_PROJECT_ID (threshold: ${CPU_UTILIZATION_THRESHOLD}%, lookback: ${METRIC_LOOKBACK_PERIOD})"

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

threshold=$(echo "$CPU_UTILIZATION_THRESHOLD" | awk '{printf "%.0f", $1}')

jq -r '.[].name' "$DISCOVERY_FILE" | while read -r svc; do
  cpu_pct=$(query_utilization_pct "run.googleapis.com/container/cpu/utilizations" "$svc")
  cpu_pct_round=$(echo "$cpu_pct" | awk '{printf "%.0f", $1}')

  echo "  Service '$svc': CPU utilization ${cpu_pct}% (threshold ${threshold}%)"

  if [ "$cpu_pct_round" -ge "$threshold" ] 2>/dev/null; then
      issue=$(jq -n \
          --arg title "Cloud Run service \`$svc\` CPU utilization is at or above threshold" \
          --arg details "Cloud Run service '$svc' in project '$GCP_PROJECT_ID' reached ${cpu_pct}% container CPU utilization over the last ${METRIC_LOOKBACK_PERIOD}, at or above the threshold of ${threshold}%. High sustained CPU can cause throttling, latency, and request failures." \
          --arg severity "3" \
          --arg expected "Container CPU utilization should remain below ${threshold}%" \
          --arg actual "Cloud Run service '$svc' reached ${cpu_pct}% CPU utilization" \
          --arg next_steps "Investigate Cloud Run service '$svc'. Increase the CPU allocation, reduce work per request, add caching, or review whether the capacity configuration matches the workload. See: gcloud run services describe $svc --project=$GCP_PROJECT_ID." \
          '{title:$title,details:$details,severity:($severity|tonumber),expected:$expected,actual:$actual,next_steps:$next_steps}')
      issues_json=$(echo "$issues_json" | jq --argjson i "$issue" '. += [$i]')
      echo "$issues_json" > "$ISSUES_FILE"
  fi
done

if [ ! -s "$ISSUES_FILE" ]; then
    echo "[]" > "$ISSUES_FILE"
fi

echo "CPU utilization check complete. Found $(jq length "$ISSUES_FILE") issue(s)."
