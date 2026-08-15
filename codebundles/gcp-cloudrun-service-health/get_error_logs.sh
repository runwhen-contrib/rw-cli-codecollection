#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Get Error Logs for Unhealthy Cloud Run Services in GCP Project
#
# REQUIRED ENV VARS:
#   GCP_PROJECT_ID  - GCP project ID to scope the API to.
#
# OPTIONAL ENV VARS:
#   RESOURCES             - Comma-separated Cloud Run service names, or 'All'.
#   ERROR_LOG_LOOKBACK    - Lookback window for log queries, e.g. '14d'. Default: 14d.
#
# Reads recent ERROR-level log entries (resource.type=cloud_run_revision) for
# every Cloud Run service within the lookback window, so the underlying failure
# cause is available for review.
#
# Writes:
#   error_logs_issues.json  - JSON array of issues (one per service with errors)
#   error_logs_report.json  - JSON array of matching log entries
# -----------------------------------------------------------------------------
set -euo pipefail

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
RESOURCES="${RESOURCES:-All}"
ERROR_LOG_LOOKBACK="${ERROR_LOG_LOOKBACK:-14d}"
# shellcheck source=./cloudrun_common.sh
source "$(dirname "$0")/cloudrun_common.sh"

ISSUES_FILE="error_logs_issues.json"
REPORT_FILE="error_logs_report.json"
echo "[]" > "$ISSUES_FILE"
echo "[]" > "$REPORT_FILE"

echo "Fetching ERROR logs for Cloud Run services in project: $GCP_PROJECT_ID (lookback=$ERROR_LOG_LOOKBACK)"

while read -r svc; do
  [ -z "$svc" ] && continue
  name=$(echo "$svc" | jq -r '.metadata.name')
  region=$(echo "$svc" | jq -r '.metadata.labels["cloud.googleapis.com/location"] // "unknown"')

  filter="resource.type=cloud_run_revision AND resource.labels.service_name=${name} AND severity>=ERROR"
  logs=$(gcloud logging read "$filter" \
    --project="$GCP_PROJECT_ID" \
    --limit=50 \
    --freshness="$ERROR_LOG_LOOKBACK" \
    --format=json 2>/dev/null || echo "[]")

  count=$(echo "$logs" | jq 'length')
  if [ "$count" -gt 0 ]; then
    echo "$logs" | jq -c --arg svc "$name" --arg region "$region" \
      '.[] | . + {serviceName: $svc, region: $region}' >> "$REPORT_FILE" 2>/dev/null || true

    # Concise per-service error summary for the report.
    messages=$(echo "$logs" | jq -r '.[] |
      (.protoPayload.status.message // .textPayload // (.jsonPayload | tostring) // .message // "")' \
      | grep -v '^$' | head -20 || true)

    add_issue "$ISSUES_FILE" "3" \
      "Cloud Run service \`$name\` in project \`$GCP_PROJECT_ID\` has ERROR logs in the last $ERROR_LOG_LOOKBACK" \
      "Service \`$name\` in region \`$region\` has $count ERROR-level log entrie(s) in the lookback window. Recent messages:\n$messages" \
      "Review the logs to identify the root cause: gcloud logging read 'resource.type=cloud_run_revision AND resource.labels.service_name=$name AND severity>=ERROR' --project=$GCP_PROJECT_ID --freshness=$ERROR_LOG_LOOKBACK" \
      "Cloud Run services should have no ERROR-level logs in the lookback window" \
      "Service \`$name\` has $count ERROR log entrie(s)"
  fi
done < <(discover_services || echo "")

if [ -s "$REPORT_FILE" ]; then
  jq -s '.' "$REPORT_FILE" > "${REPORT_FILE}.tmp" && mv "${REPORT_FILE}.tmp" "$REPORT_FILE"
else
  echo "[]" > "$REPORT_FILE"
fi

echo "Error log check complete. Found $(jq length "$ISSUES_FILE") issues."
