#!/usr/bin/env bash
set -euo pipefail
set -x
# -----------------------------------------------------------------------------
# Summarizes classified_events.json: counts by actor and operation
# Writes summary_issues.json (usually []) and prints human-readable report
# -----------------------------------------------------------------------------

: "${AZURE_SUBSCRIPTION_ID:?Must set AZURE_SUBSCRIPTION_ID}"

OUTPUT_ISSUES="summary_issues.json"
SUB_ID="$AZURE_SUBSCRIPTION_ID"
PORTAL_URL="https://portal.azure.com/#view/Microsoft_Azure_Monitor/ActivityLogBlade/subscriptionId/${SUB_ID}"

if [[ ! -f classified_events.json ]]; then
  echo "[]" > "$OUTPUT_ISSUES"
  echo "No classified_events.json yet. Run prior tasks."
  exit 0
fi

classified=$(cat classified_events.json)

summary_json=$(echo "$classified" | jq \
  --arg portal "$PORTAL_URL" \
  '{
    total: length,
    by_classification: (group_by(.classification) | map({key: .[0].classification, value: length}) | from_entries),
    top_callers: (group_by(.caller // "unknown") | map({caller: .[0].caller, count: length}) | sort_by(-.count) | .[0:10]),
    top_operations: (group_by(.operationName) | map({operation: .[0].operationName, count: length}) | sort_by(-.count) | .[0:10]),
    activity_log_portal_url: $portal
  }')

echo "$summary_json" | jq .

echo ""
echo "=== Azure NSG / Firewall Activity Summary ==="
echo "Subscription: $SUB_ID"
echo "Portal (Activity Log): $PORTAL_URL"
echo "$summary_json" | jq -r '
  "Total events (classified): \(.total)",
  "",
  "By classification:",
  (.by_classification | to_entries[] | "  \(.key): \(.value)"),
  "",
  "Top callers:",
  (.top_callers[] | "  \(.caller): \(.count)"),
  "",
  "Top operations:",
  (.top_operations[] | "  \(.operation): \(.count)")
'

echo '[]' > "$OUTPUT_ISSUES"
echo "Summary complete."
