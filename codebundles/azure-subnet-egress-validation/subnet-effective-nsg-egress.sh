#!/usr/bin/env bash
# Summarizes effective NSG outbound rules per subnet (subnet-attached NSG).
# Writes subnet_effective_nsg_issues.json and subnet_effective_nsg_summary.json
set -euo pipefail
set -x

: "${AZURE_SUBSCRIPTION_ID:?Must set AZURE_SUBSCRIPTION_ID}"
: "${AZURE_RESOURCE_GROUP:?Must set AZURE_RESOURCE_GROUP}"
: "${VNET_NAME:?Must set VNET_NAME}"

OUTPUT_FILE="subnet_effective_nsg_issues.json"
SUMMARY_JSON="subnet_effective_nsg_summary.json"
issues_json='[]'
summary='[]'

az account set --subscription "$AZURE_SUBSCRIPTION_ID" 2>/dev/null || true

subnet_names=$(az network vnet subnet list \
  --resource-group "$AZURE_RESOURCE_GROUP" \
  --vnet-name "$VNET_NAME" \
  --subscription "$AZURE_SUBSCRIPTION_ID" \
  --query "[].name" -o tsv 2>/dev/null || true)

while IFS= read -r sn; do
  [ -z "$sn" ] && continue
  sub_json=$(az network vnet subnet show \
    --resource-group "$AZURE_RESOURCE_GROUP" \
    --vnet-name "$VNET_NAME" \
    --name "$sn" \
    --subscription "$AZURE_SUBSCRIPTION_ID" \
    -o json 2>/dev/null || echo "{}")

  nsg_id=$(echo "$sub_json" | jq -r '.networkSecurityGroup.id // ""')
  if [ -z "$nsg_id" ] || [ "$nsg_id" = "null" ]; then
    issues_json=$(echo "$issues_json" | jq \
      --arg title "Subnet \`$sn\` has no NSG attached" \
      --arg details "Without an NSG, Azure platform default rules apply; subnet-level traffic filtering is not explicit." \
      --arg severity "2" \
      --arg next_steps "Associate an NSG with the subnet or confirm intent to rely on NIC-level NSGs only." \
      '. += [{
        "title": $title,
        "details": $details,
        "severity": ($severity | tonumber),
        "next_steps": $next_steps
      }]')
    summary=$(echo "$summary" | jq \
      --arg subnet "$sn" \
      --argjson rules '[]' \
      --arg note "no subnet NSG" \
      '. += [{
        "subnetName": $subnet,
        "outboundRules": $rules,
        "note": $note
      }]')
    continue
  fi

  nsg_name=$(basename "$nsg_id")
  nsg_rg=$(echo "$nsg_id" | sed -n 's|.*/resourceGroups/\([^/]*\)/providers/.*|\1|p')
  if [ -z "$nsg_rg" ]; then
    nsg_rg="$AZURE_RESOURCE_GROUP"
  fi

  rules_json=$(az network nsg rule list \
    --resource-group "$nsg_rg" \
    --nsg-name "$nsg_name" \
    --subscription "$AZURE_SUBSCRIPTION_ID" \
    -o json 2>/dev/null || echo "[]")

  outbound=$(echo "$rules_json" | jq '[.[] | select(.direction == "Outbound")]')
  deny_count=$(echo "$outbound" | jq '[.[] | select(.access == "Deny")] | length')

  summary=$(echo "$summary" | jq \
    --arg subnet "$sn" \
    --arg nsg "$nsg_name" \
    --argjson outbound "$outbound" \
    --argjson deny_count "$deny_count" \
    '. += [{
      "subnetName": $subnet,
      "nsgName": $nsg,
      "outboundRuleCount": ($outbound | length),
      "denyRuleCount": $deny_count,
      "outboundRules": $outbound
    }]')
done <<< "$subnet_names"

echo "$summary" > "$SUMMARY_JSON"
echo "$issues_json" > "$OUTPUT_FILE"

echo "Effective NSG egress summary:"
echo "$summary" | jq '[.[] | {subnetName, nsgName, outboundRuleCount, denyRuleCount}]'
echo "Issues written to $OUTPUT_FILE"
