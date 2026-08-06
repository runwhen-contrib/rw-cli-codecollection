#!/usr/bin/env bash
# Discovers subnets in the VNet and resolves attached NSGs and route tables.
# Writes JSON array of issues to subnet_discover_issues.json
set -euo pipefail
set -x

: "${AZURE_SUBSCRIPTION_ID:?Must set AZURE_SUBSCRIPTION_ID}"
: "${AZURE_RESOURCE_GROUP:?Must set AZURE_RESOURCE_GROUP}"
: "${VNET_NAME:?Must set VNET_NAME}"

OUTPUT_FILE="subnet_discover_issues.json"
DISCOVERY_JSON="subnet_discovery.json"
issues_json='[]'

if ! az account set --subscription "$AZURE_SUBSCRIPTION_ID" 2>/dev/null; then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Cannot set Azure subscription \`$AZURE_SUBSCRIPTION_ID\`" \
    --arg details "az account set failed. Verify credentials and subscription access." \
    --arg severity "4" \
    --arg next_steps "Confirm the service principal can read the subscription and AZURE_SUBSCRIPTION_ID is correct." \
    '. += [{
      "title": $title,
      "details": $details,
      "severity": ($severity | tonumber),
      "next_steps": $next_steps
    }]')
  echo "$issues_json" > "$OUTPUT_FILE"
  echo "[]" > "$DISCOVERY_JSON"
  exit 0
fi

if ! vnet_json=$(az network vnet show \
  --resource-group "$AZURE_RESOURCE_GROUP" \
  --name "$VNET_NAME" \
  --subscription "$AZURE_SUBSCRIPTION_ID" \
  -o json 2>/dev/null); then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Virtual network not found: \`$VNET_NAME\`" \
    --arg details "az network vnet show failed for resource group \`$AZURE_RESOURCE_GROUP\`." \
    --arg severity "4" \
    --arg next_steps "Verify VNET_NAME and AZURE_RESOURCE_GROUP. Ensure the VNet exists in the subscription." \
    '. += [{
      "title": $title,
      "details": $details,
      "severity": ($severity | tonumber),
      "next_steps": $next_steps
    }]')
  echo "$issues_json" > "$OUTPUT_FILE"
  echo "[]" > "$DISCOVERY_JSON"
  exit 0
fi

subnet_names=$(az network vnet subnet list \
  --resource-group "$AZURE_RESOURCE_GROUP" \
  --vnet-name "$VNET_NAME" \
  --subscription "$AZURE_SUBSCRIPTION_ID" \
  --query "[].name" -o tsv 2>/dev/null || true)

if [ -z "${subnet_names//[$'\t\r\n']/}" ]; then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "No subnets found in VNet \`$VNET_NAME\`" \
    --arg details "The virtual network has no subnets to analyze." \
    --arg severity "2" \
    --arg next_steps "Create subnets in the VNet or confirm the correct VNet name." \
    '. += [{
      "title": $title,
      "details": $details,
      "severity": ($severity | tonumber),
      "next_steps": $next_steps
    }]')
fi

discovery='[]'
while IFS= read -r sn; do
  [ -z "$sn" ] && continue
  sub_json=$(az network vnet subnet show \
    --resource-group "$AZURE_RESOURCE_GROUP" \
    --vnet-name "$VNET_NAME" \
    --name "$sn" \
    --subscription "$AZURE_SUBSCRIPTION_ID" \
    -o json 2>/dev/null || echo "{}")
  nsg_id=$(echo "$sub_json" | jq -r '.networkSecurityGroup.id // ""')
  rt_id=$(echo "$sub_json" | jq -r '.routeTable.id // ""')
  discovery=$(echo "$discovery" | jq \
    --arg name "$sn" \
    --arg nsg "$nsg_id" \
    --arg rt "$rt_id" \
    '. += [{
      "subnetName": $name,
      "networkSecurityGroupId": $nsg,
      "routeTableId": $rt
    }]')
done <<< "$subnet_names"

echo "$discovery" > "$DISCOVERY_JSON"

echo "Subnet discovery for VNet \`$VNET_NAME\` (subscription $AZURE_SUBSCRIPTION_ID, RG $AZURE_RESOURCE_GROUP):"
echo "$discovery" | jq .

echo "$issues_json" > "$OUTPUT_FILE"
echo "Discovery complete. Issues saved to $OUTPUT_FILE"
