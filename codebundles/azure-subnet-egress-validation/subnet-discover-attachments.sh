#!/usr/bin/env bash
set -euo pipefail
set -x
# -----------------------------------------------------------------------------
# REQUIRED ENV VARS:
#   AZURE_SUBSCRIPTION_ID
#   AZURE_RESOURCE_GROUP
#   VNET_NAME
#
# OPTIONAL:
#   SUBNET_NAME_FILTER  Comma-separated subnet names (empty = all)
#
# Outputs:
#   discovered_subnets.json   Array of subnet attachment metadata
#   subnet_discover_issues.json  JSON array of issues
# -----------------------------------------------------------------------------

: "${AZURE_SUBSCRIPTION_ID:?Must set AZURE_SUBSCRIPTION_ID}"
: "${AZURE_RESOURCE_GROUP:?Must set AZURE_RESOURCE_GROUP}"
: "${VNET_NAME:?Must set VNET_NAME}"

OUTPUT_DISCOVERY="discovered_subnets.json"
OUTPUT_ISSUES="subnet_discover_issues.json"
issues_json='[]'

az account set --subscription "${AZURE_SUBSCRIPTION_ID}" >/dev/null 2>&1 || true

if ! subnet_list=$(az network vnet subnet list \
  --resource-group "${AZURE_RESOURCE_GROUP}" \
  --vnet-name "${VNET_NAME}" \
  -o json 2>err_discover.log); then
  err_msg=$(cat err_discover.log 2>/dev/null || echo "unknown error")
  rm -f err_discover.log
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Cannot List Subnets for VNet \`${VNET_NAME}\`" \
    --arg details "az network vnet subnet list failed: $err_msg" \
    --arg severity "4" \
    --arg next_steps "Verify AZURE_RESOURCE_GROUP and VNET_NAME, subscription access, and that the VNet exists." \
    '. += [{
       "title": $title,
       "details": $details,
       "severity": ($severity | tonumber),
       "next_steps": $next_steps
     }]')
  echo "$issues_json" > "$OUTPUT_ISSUES"
  echo '[]' > "$OUTPUT_DISCOVERY"
  echo "Discovery failed; see $OUTPUT_ISSUES"
  exit 0
fi
rm -f err_discover.log

# Optional name filter
if [[ -n "${SUBNET_NAME_FILTER:-}" ]]; then
  subnet_list=$(echo "$subnet_list" | jq --arg csv "${SUBNET_NAME_FILTER}" '
    ($csv | split(",") | map(gsub("^\\s+|\\s+$";""))) as $names
    | map(select(.name as $n | $names | index($n) != null))
  ')
fi

echo "$subnet_list" | jq '[.[] | {
  name: .name,
  id: .id,
  addressPrefix: (.addressPrefix // .addressPrefixes[0] // ""),
  networkSecurityGroup: .networkSecurityGroup,
  routeTable: .routeTable
}]' > "$OUTPUT_DISCOVERY"

count=$(jq 'length' "$OUTPUT_DISCOVERY")
if [[ "$count" -eq 0 ]]; then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "No Subnets In Scope for VNet \`${VNET_NAME}\`" \
    --arg details "Subnet list is empty after discovery (check SUBNET_NAME_FILTER if set)." \
    --arg severity "2" \
    --arg next_steps "Confirm the VNet contains subnets and that filters match intended subnet names." \
    '. += [{
       "title": $title,
       "details": $details,
       "severity": ($severity | tonumber),
       "next_steps": $next_steps
     }]')
fi

echo "$issues_json" > "$OUTPUT_ISSUES"
echo "Discovery completed: $count subnet(s) written to $OUTPUT_DISCOVERY"
