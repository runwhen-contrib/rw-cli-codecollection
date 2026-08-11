#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Report Cloud Run utilization and scaling configuration for a GCP project.
#
# Captures CPU/memory utilization metrics and the scaling configuration (max/
# min instances, concurrency, CPU/memory allocation) for every Cloud Run service
# into a JSON report. This data is included in the report so an LLM can perform
# cost and sizing review. Raises no issues by itself.
#
# REQUIRED ENV VARS:
#   GCP_PROJECT_ID           - GCP project ID
#   RESOURCES                - Comma-separated service names, or "All" (default)
#   METRIC_LOOKBACK_PERIOD   - Lookback window (default 3600s)
#
# OUTPUTS:
#   utilization_report.json     - JSON array of per-service utilization + config
#   utilization_report_issues.json - Always an empty array (report task)
# -----------------------------------------------------------------------------
set -euo pipefail
set -x

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
: "${RESOURCES:=All}"
: "${METRIC_LOOKBACK_PERIOD:=3600s}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPORT_FILE="utilization_report.json"
ISSUES_FILE="utilization_report_issues.json"

lookback_sec=${METRIC_LOOKBACK_PERIOD%s}
now_epoch=$(date +%s)
start_epoch=$(( now_epoch - lookback_sec ))
START_TIME=$(date -u -d "@$start_epoch" "+%Y-%m-%dT%H:%M:%SZ")
END_TIME=$(date -u -d "@$now_epoch" "+%Y-%m-%dT%H:%M:%SZ")

echo "Capturing Cloud Run utilization and scaling report for project: $GCP_PROJECT_ID (lookback: ${METRIC_LOOKBACK_PERIOD})"

ACCESS_TOKEN=$(gcloud auth print-access-token 2>/dev/null || echo "")
if [ -z "$ACCESS_TOKEN" ]; then
    echo "[]" > "$REPORT_FILE"
    echo "[]" > "$ISSUES_FILE"
    echo "Warning: unable to authenticate to Cloud Monitoring; report is empty."
    exit 0
fi

source "$SCRIPT_DIR/discover_services.sh"
source "$SCRIPT_DIR/monitoring_query.sh"

helper_query() {
    query_utilization_pct "$1" "$2"
}

jq -c '.[]' "$DISCOVERY_FILE" | while read -r svc; do
  name=$(echo "$svc" | jq -r '.name')
  cpu_pct=$(helper_query "run.googleapis.com/container/cpu/utilizations" "$name")
  mem_pct=$(helper_query "run.googleapis.com/container/memory/utilizations" "$name")
  echo "$svc" | jq -c --arg cpu "$cpu_pct" --arg mem "$mem_pct" \
      '. + {cpuUtilizationPct: ($cpu|tonumber), memoryUtilizationPct: ($mem|tonumber), observedAt: now}' >> "$REPORT_FILE"
done

jq -s '.' "$REPORT_FILE" > "${REPORT_FILE}.tmp" && mv "${REPORT_FILE}.tmp" "$REPORT_FILE"
echo "[]" > "$ISSUES_FILE"

echo "Utilization report captured for $(jq length "$REPORT_FILE") Cloud Run service(s). See $REPORT_FILE"
