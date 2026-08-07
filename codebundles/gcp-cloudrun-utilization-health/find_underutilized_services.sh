#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Identify under-utilized or idle Cloud Run services in a GCP project.
#
# Flags services whose sustained container CPU utilization stays below
# MIN_UTILIZATION_THRESHOLD over the lookback window. Such services are
# over-provisioned / idle and are candidates for right-sizing or scaling to
# zero, surfacing wasted capacity for LLM-based cost review.
#
# REQUIRED ENV VARS:
#   GCP_PROJECT_ID           - GCP project ID
#   RESOURCES                - Comma-separated service names, or "All" (default)
#   METRIC_LOOKBACK_PERIOD   - Lookback window (default 3600s)
#   MIN_UTILIZATION_THRESHOLD- Low utilization percent below which a service is
#                              considered under-utilized (default 10)
#
# OUTPUTS:
#   underutilized_issues.json - JSON array of issues
# -----------------------------------------------------------------------------
set -euo pipefail
set -x

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
: "${RESOURCES:=All}"
: "${METRIC_LOOKBACK_PERIOD:=3600s}"
: "${MIN_UTILIZATION_THRESHOLD:=10}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ISSUES_FILE="underutilized_issues.json"
issues_json='[]'

lookback_sec=${METRIC_LOOKBACK_PERIOD%s}
now_epoch=$(date +%s)
start_epoch=$(( now_epoch - lookback_sec ))
START_TIME=$(date -u -d "@$start_epoch" "+%Y-%m-%dT%H:%M:%SZ")
END_TIME=$(date -u -d "@$now_epoch" "+%Y-%m-%dT%H:%M:%SZ")

echo "Identifying under-utilized Cloud Run services for project: $GCP_PROJECT_ID (min utilization threshold: ${MIN_UTILIZATION_THRESHOLD}%, lookback: ${METRIC_LOOKBACK_PERIOD})"

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

min_threshold=$(echo "$MIN_UTILIZATION_THRESHOLD" | awk '{printf "%.0f", $1}')

jq -c '.[]' "$DISCOVERY_FILE" | while read -r svc; do
  name=$(echo "$svc" | jq -r '.name')
  min_scale=$(echo "$svc" | jq -r '.minScale')
  cpu_pct=$(query_utilization_pct "run.googleapis.com/container/cpu/utilizations" "$name")
  cpu_pct_round=$(echo "$cpu_pct" | awk '{printf "%.0f", $1}')

  echo "  Service '$name': CPU utilization ${cpu_pct}% (under-utilized below ${min_threshold}%)"

  if [ "$cpu_pct_round" -lt "$min_threshold" ] 2>/dev/null; then
    warm_hint=""
    if [ -n "$min_scale" ] && [ "$min_scale" != "0" ]; then
      warm_hint=" This service also keeps ${min_scale} minimum instance(s) warm and billed."
    fi
    issue=$(jq -n \
        --arg title "Cloud Run service \`$name\` is under-utilized" \
        --arg details "Cloud Run service '$name' in project '$GCP_PROJECT_ID' sustained only ${cpu_pct}% container CPU utilization over the last ${METRIC_LOOKBACK_PERIOD}, below the under-utilization threshold of ${min_threshold}%. The service appears over-provisioned or idle.$warm_hint" \
        --arg severity "2" \
        --arg expected "Cloud Run services should have utilization at or above ${min_threshold}% of their allocation" \
        --arg actual "Cloud Run service '$name' sustained ${cpu_pct}% CPU utilization" \
        --arg next_steps "Review whether Cloud Run service '$name' can be right-sized, scaled to zero during idle periods, or is a candidate for removal. Reduce CPU/memory allocation or set min instances to 0 to stop keeping idle instances warm. See: gcloud run services describe $name --project=$GCP_PROJECT_ID." \
        '{title:$title,details:$details,severity:($severity|tonumber),expected:$expected,actual:$actual,next_steps:$next_steps}')
    issues_json=$(echo "$issues_json" | jq --argjson i "$issue" '. += [$i]')
    echo "$issues_json" > "$ISSUES_FILE"
  fi
done

if [ ! -s "$ISSUES_FILE" ]; then
    echo "[]" > "$ISSUES_FILE"
fi

echo "Under-utilized service check complete. Found $(jq length "$ISSUES_FILE") issue(s)."
