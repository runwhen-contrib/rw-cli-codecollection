#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# REQUIRED ENV VARS:
#   GCP_PROJECT_ID
#
# OPTIONAL ENV VARS:
#   SERVICES                 Comma-separated service names to check; 'All' checks all enabled services
#   LOOKBACK_MINUTES         Lookback window (minutes) for Cloud Logging rejection events
#   REJECTION_THRESHOLD      Minimum number of quota rejection events in the window that triggers an issue
#
# This script queries Cloud Logging over the lookback window for quota rejection
# events (HTTP 429 RESOURCE_EXHAUSTED / 403 quota exceeded) across services and
# aggregates them by service and quota metric, raising issues when the rejection
# volume exceeds the configured REJECTION_THRESHOLD.
# Outputs a JSON array of issues to quota_rejection_issues.json
# -----------------------------------------------------------------------------

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
: "${SERVICES:=All}"
: "${LOOKBACK_MINUTES:=1440}"
: "${REJECTION_THRESHOLD:=1}"

OUTPUT_FILE="quota_rejection_issues.json"
ISSUES_TMP="$(mktemp)"
trap 'rm -f "$ISSUES_TMP"' EXIT

echo "Analyzing quota rejection events from Cloud Logging for project: $GCP_PROJECT_ID"

token=$(gcloud auth print-access-token 2>/dev/null || echo "")
if [ -z "$token" ]; then
  echo "Unable to obtain an access token; no rejection events analyzed."
  echo "[]" > "$OUTPUT_FILE"
  exit 0
fi

now_epoch=$(date +%s)
start_epoch=$((now_epoch - LOOKBACK_MINUTES * 60))
start_rfc3339=$(python3 -c "import datetime;print(datetime.datetime.fromtimestamp(int('$start_epoch')), 'Z')" 2>/dev/null || echo "")
start_rfc3339=$(python3 -c "
import datetime
print(datetime.datetime.utcfromtimestamp(int('$start_epoch')).isoformat() + 'Z')
" 2>/dev/null || echo "")

# Cloud Logging filter for quota rejection events
LOG_FILTER='(protoPayload.status.code=8 OR httpRequest.status=429 OR "RESOURCE_EXHAUSTED" OR "quota exceeded" OR "Quota exceeded" OR "quota limit")'

reject_payload=$(curl -s -X POST -H "Authorization: Bearer $token" -H "Content-Type: application/json" \
  -d "$(jq -n \
    --arg project "$GCP_PROJECT_ID" \
    --arg filter "$LOG_FILTER AND timestamp>=\"$start_rfc3339\"" \
    '{resourceNames:[("projects/"+$project)], filter:$filter, orderBy:"timestamp desc", pageSize:500}')" \
  "https://logging.googleapis.com/v2/entries:list" 2>/dev/null || echo "{}")

if ! echo "$reject_payload" | jq -e '.entries' >/dev/null 2>&1; then
  echo "Cloud Logging returned no entries (no quota rejections in window, or insufficient permission)."
  echo "[]" > "$OUTPUT_FILE"
  exit 0
fi

# Aggregate rejection events by service and quota metric
aggregated=$(echo "$reject_payload" | jq -c '
  [.entries[]? |
    {
      service: (.resource.labels.service // .resource.labels.service_id // .resource.labels.project_id // "unknown"),
      metric: (.protoPayload.response.details // .protoPayload.status.message // .jsonPayload.message // "quota")
    }]
  | group_by(.service + "|" + .metric)
  | map({service: .[0].service, metric: .[0].metric, count: length})' 2>/dev/null || echo '[]')

echo "$aggregated" | jq -c '.[]' | while IFS= read -r group; do
  service=$(echo "$group" | jq -r '.service')
  metric=$(echo "$group" | jq -r '.metric')
  count=$(echo "$group" | jq -r '.count // 0')

  if [ -n "$SERVICES" ] && [ "$SERVICES" != "All" ] && [ "$SERVICES" != "all" ]; then
    case ",$SERVICES," in
      *,"$service",*) ;;
      *) continue ;;
    esac
  fi

  if python3 -c "import sys; sys.exit(0 if int('$count') >= int('$REJECTION_THRESHOLD') else 1)" 2>/dev/null; then
    if python3 -c "import sys; sys.exit(0 if int('$count') >= 100 else 1)" 2>/dev/null; then
      severity="4"
    elif python3 -c "import sys; sys.exit(0 if int('$count') >= 20 else 1)" 2>/dev/null; then
      severity="3"
    else
      severity="2"
    fi

    jq -n \
      --arg title "Quota rejection events detected for service \`$service\` in project \`$GCP_PROJECT_ID\`" \
      --arg details "Cloud Logging shows ${count} quota rejection event(s) (HTTP 429 RESOURCE_EXHAUSTED / quota exceeded) for service \`$service\`, metric \`$metric\`, over the last ${LOOKBACK_MINUTES} minutes. Threshold is ${REJECTION_THRESHOLD}." \
      --arg expected "Quota rejection events should remain below the configured ${REJECTION_THRESHOLD} threshold" \
      --arg actual "${count} quota rejection event(s) detected for service \`$service\` (metric \`$metric\`)" \
      --arg severity "$severity" \
      --arg next_steps "Investigate API calls to service $service that are being rejected for quota \`$metric\`. Add retry/backoff, reduce request volume, or request a quota increase via the Cloud Quotas page." \
      '{title:$title,details:$details,expected:$expected,actual:$actual,severity:($severity|tonumber),next_steps:$next_steps}' >> "$ISSUES_TMP"
  fi
done

if [ -s "$ISSUES_TMP" ]; then
  jq -s '.' "$ISSUES_TMP" > "$OUTPUT_FILE"
else
  echo "[]" > "$OUTPUT_FILE"
fi

echo "Quota rejection analysis completed: $(jq length "$OUTPUT_FILE") issue(s)."

echo ""
echo "=== LLM Context ==="
echo "Project: $GCP_PROJECT_ID"
echo "Lookback window: ${LOOKBACK_MINUTES} minutes"
echo "Rejection threshold: ${REJECTION_THRESHOLD}"
echo "Cloud Logging console: https://console.cloud.google.com/logs/query?project=$GCP_PROJECT_ID"
