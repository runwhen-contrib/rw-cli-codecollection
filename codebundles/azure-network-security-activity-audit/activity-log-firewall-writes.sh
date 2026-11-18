#!/usr/bin/env bash
set -euo pipefail
set -x
# -----------------------------------------------------------------------------
# Lists write/delete/action operations on Azure Firewall and Firewall Policy resources.
# Writes: firewall_writes_raw.json, firewall_issues.json
# -----------------------------------------------------------------------------

: "${AZURE_SUBSCRIPTION_ID:?Must set AZURE_SUBSCRIPTION_ID}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/azure_activity_log_common.sh"

OUTPUT_ISSUES="firewall_issues.json"
OUTPUT_RAW="firewall_writes_raw.json"
issues_json='[]'

az account set --subscription "${AZURE_SUBSCRIPTION_ID}" || {
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Cannot set Azure subscription context" \
    --arg details "az account set failed; verify credentials" \
    --argjson severity 4 \
    --arg next_steps "Confirm AZURE_SUBSCRIPTION_ID and azure_credentials" \
    '. += [{"title": $title, "details": $details, "severity": $severity, "next_steps": $next_steps}]')
  echo "$issues_json" > "$OUTPUT_ISSUES"
  echo "[]" > "$OUTPUT_RAW"
  exit 0
}

if ! raw_json=$(activity_fetch_network_events); then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Activity log query failed for Azure Firewall audit" \
    --arg details "az monitor activity-log list returned an error" \
    --argjson severity 4 \
    --arg next_steps "Verify Reader access and retry" \
    '. += [{"title": $title, "details": $details, "severity": $severity, "next_steps": $next_steps}]')
  echo "$issues_json" > "$OUTPUT_ISSUES"
  echo "[]" > "$OUTPUT_RAW"
  exit 0
fi

filtered=$(echo "$raw_json" | jq '[.[] | select((.operationName.value // "") | test("azureFirewalls|firewallPolicies|ruleCollectionGroups|ruleCollections")) | select((.operationName.value // "") | test("/(write|delete|action)$"))]')
echo "$filtered" > "$OUTPUT_RAW"

failed_count=$(echo "$filtered" | jq '[.[] | select((.status.value // "") != "Succeeded" and (.status.value // "") != "")] | length')
if [[ "$failed_count" -gt 0 ]]; then
  failed_sample=$(echo "$filtered" | jq '[.[] | select((.status.value // "") != "Succeeded" and (.status.value // "") != "")] | .[0:5]')
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Azure Firewall or policy activity reported non-success status" \
    --arg details "$(echo "$failed_sample" | jq -c .)" \
    --argjson severity 2 \
    --arg next_steps "Review failed operations in Activity Log for the firewall or policy resource" \
    '. += [{"title": $title, "details": $details, "severity": $severity, "next_steps": $next_steps}]')
fi

mut_count=$(echo "$filtered" | jq 'length')
if [[ "$mut_count" -gt 50 ]]; then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "High volume of firewall or policy mutations (possible truncation)" \
    --arg details "Observed ${mut_count} events; Microsoft.Network activity log query is capped at 500 events." \
    --argjson severity 3 \
    --arg next_steps "Narrow time range or scope, or use Log Analytics for exhaustive history" \
    '. += [{"title": $title, "details": $details, "severity": $severity, "next_steps": $next_steps}]')
fi

echo "$issues_json" > "$OUTPUT_ISSUES"
echo "Firewall/policy mutation events in window: ${mut_count}"
exit 0
