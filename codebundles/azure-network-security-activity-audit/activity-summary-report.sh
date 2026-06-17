#!/usr/bin/env bash
set -euo pipefail
set -x
# -----------------------------------------------------------------------------
# Summarizes counts by operation and caller; portal deep link for Activity Log.
# Writes summary_report.json (payload) and summary_issues.json (informational issues).
# -----------------------------------------------------------------------------

: "${AZURE_SUBSCRIPTION_ID:?Must set AZURE_SUBSCRIPTION_ID}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

OUTPUT_SUMMARY="summary_report.json"
OUTPUT_ISSUES="summary_issues.json"

merge_raw() {
  local nsg="[]"
  local fw="[]"
  [[ -f nsg_writes_raw.json ]] && nsg=$(cat nsg_writes_raw.json)
  [[ -f firewall_writes_raw.json ]] && fw=$(cat firewall_writes_raw.json)
  echo "$nsg" "$fw" | jq -s 'add'
}

merged=$(merge_raw)
tenant="${AZURE_TENANT_ID:-}"
if [[ -z "$tenant" ]] && command -v az >/dev/null 2>&1; then
  tenant=$(az account show --query tenantId -o tsv 2>/dev/null || echo "")
fi

portal="https://portal.azure.com/#blade/Microsoft_Azure_Monitoring/AzureActivityLogBlade/subscriptionId/${AZURE_SUBSCRIPTION_ID}"

summary=$(echo "$merged" | jq -n \
  --argjson ev "$merged" \
  --arg sub "${AZURE_SUBSCRIPTION_ID}" \
  --arg portal "$portal" \
  --arg tenant "$tenant" \
  '{
    subscriptionId: $sub,
    tenantId: $tenant,
    totalEvents: ($ev | length),
    byOperation: ($ev | group_by(.operationName.value // "unknown") | map({operation: (.[0].operationName.value // "unknown"), count: length})),
    byCaller: ($ev | group_by(.caller // "unknown") | map({caller: (.[0].caller // "unknown"), count: length}) | sort_by(-.count)),
    activityLogPortalUrl: $portal
  }')

echo "$summary" | jq . > "$OUTPUT_SUMMARY"

issues_json='[]'
total=$(echo "$merged" | jq 'length')
issues_json=$(echo "$issues_json" | jq \
  --arg title "Activity audit summary for subscription" \
  --arg details "$(echo "$summary" | jq -c .)" \
  --argjson severity 1 \
  --arg next_steps "Use the activityLogPortalUrl in the report to open the subscription Activity Log; tune allowlists and lookback as needed" \
  '. += [{"title": $title, "details": $details, "severity": $severity, "next_steps": $next_steps}]')

if [[ "$total" -eq 0 ]]; then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "No NSG or firewall mutation events in captured window" \
    --arg details "Merged NSG + firewall filtered events is zero (or raw files missing). Confirm scope, lookback, and that Microsoft.Network activity exists." \
    --argjson severity 2 \
    --arg next_steps "Verify AZURE_RESOURCE_GROUP if set, increase ACTIVITY_LOOKBACK_HOURS, or check for CLI max-events limits" \
    '. += [{"title": $title, "details": $details, "severity": $severity, "next_steps": $next_steps}]')
fi

echo "$issues_json" > "$OUTPUT_ISSUES"
cat "$OUTPUT_SUMMARY"
exit 0
