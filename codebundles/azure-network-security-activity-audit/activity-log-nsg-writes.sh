#!/usr/bin/env bash
set -euo pipefail
set -x
# -----------------------------------------------------------------------------
# Lists write/delete/action operations on NSGs and NSG rules in the lookback window.
# Writes: nsg_writes_raw.json (filtered events), nsg_issues.json (issue array for Robot).
# Env: AZURE_SUBSCRIPTION_ID, optional AZURE_RESOURCE_GROUP, ACTIVITY_LOOKBACK_HOURS
# -----------------------------------------------------------------------------

: "${AZURE_SUBSCRIPTION_ID:?Must set AZURE_SUBSCRIPTION_ID}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/azure_activity_log_common.sh"

OUTPUT_ISSUES="nsg_issues.json"
OUTPUT_RAW="nsg_writes_raw.json"
issues_json='[]'

az account set --subscription "${AZURE_SUBSCRIPTION_ID}" || {
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Cannot set Azure subscription context" \
    --arg details "az account set failed; verify azure_credentials and AZURE_SUBSCRIPTION_ID" \
    --argjson severity 4 \
    --arg next_steps "Confirm the service principal has Reader on the subscription and IDs are correct" \
    '. += [{"title": $title, "details": $details, "severity": $severity, "next_steps": $next_steps}]')
  echo "$issues_json" > "$OUTPUT_ISSUES"
  echo "[]" > "$OUTPUT_RAW"
  exit 0
}

if ! raw_json=$(activity_fetch_network_events); then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Activity log query failed for NSG audit" \
    --arg details "az monitor activity-log list returned an error; see stderr above" \
    --argjson severity 4 \
    --arg next_steps "Verify Reader role includes Activity Log access and retry" \
    '. += [{"title": $title, "details": $details, "severity": $severity, "next_steps": $next_steps}]')
  echo "$issues_json" > "$OUTPUT_ISSUES"
  echo "[]" > "$OUTPUT_RAW"
  exit 0
fi

filtered=$(echo "$raw_json" | jq '[.[] | select((.operationName.value // "") | test("networkSecurityGroups")) | select((.operationName.value // "") | test("/(write|delete|action)$"))]')
echo "$filtered" > "$OUTPUT_RAW"

failed_count=$(echo "$filtered" | jq '[.[] | select((.status.value // "") != "Succeeded" and (.status.value // "") != "")] | length')
if [[ "$failed_count" -gt 0 ]]; then
  failed_sample=$(echo "$filtered" | jq '[.[] | select((.status.value // "") != "Succeeded" and (.status.value // "") != "")] | .[0:5]')
  issues_json=$(echo "$issues_json" | jq \
    --arg title "NSG-related activity log operations reported non-success status" \
    --arg details "$(echo "$failed_sample" | jq -c .)" \
    --argjson severity 2 \
    --arg next_steps "Review failed operations in the Activity Log and remediate RBAC or quota issues" \
    '. += [{"title": $title, "details": $details, "severity": $severity, "next_steps": $next_steps}]')
fi

mut_count=$(echo "$filtered" | jq 'length')
if [[ "$mut_count" -gt 50 ]]; then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "High volume of NSG mutations in lookback window (possible truncation)" \
    --arg details "Observed ${mut_count} NSG write/delete/action events; CLI returns at most 500 Microsoft.Network events per query. Narrow scope or shorten ACTIVITY_LOOKBACK_HOURS." \
    --argjson severity 3 \
    --arg next_steps "Reduce lookback, scope to a resource group, or export logs to Log Analytics for full history" \
    '. += [{"title": $title, "details": $details, "severity": $severity, "next_steps": $next_steps}]')
fi

echo "$issues_json" > "$OUTPUT_ISSUES"
echo "NSG mutation events (writes/deletes/actions) in window: ${mut_count} (raw cap 500 Microsoft.Network events per query)"
exit 0
