#!/usr/bin/env bash
# Export live NSG rules and associations into canonical JSON for drift comparison.
# Outputs: nsg_live_export.json, nsg_export_issues.json (array)
set -euo pipefail
set -x

: "${AZURE_SUBSCRIPTION_ID:?Must set AZURE_SUBSCRIPTION_ID}"
: "${NSG_NAME:?Must set NSG_NAME}"

OUTPUT_JSON="nsg_live_export.json"
ISSUES_JSON="nsg_export_issues.json"

issues_json='[]'

resolve_rg() {
  local nsg="$1"
  if [ -n "${AZURE_RESOURCE_GROUP:-}" ]; then
    echo "$AZURE_RESOURCE_GROUP"
    return 0
  fi
  az network nsg list --subscription "$AZURE_SUBSCRIPTION_ID" -o json 2>/dev/null \
    | jq -r --arg n "$nsg" '.[] | select(.name == $n) | .resourceGroup' | head -1
}

RG="$(resolve_rg "$NSG_NAME")"
if [ -z "$RG" ]; then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Cannot resolve resource group for NSG \`$NSG_NAME\`" \
    --arg details "NSG not found in subscription or AZURE_RESOURCE_GROUP not set." \
    --argjson severity 4 \
    --arg next_steps "Verify NSG name and subscription; set AZURE_RESOURCE_GROUP if discovery fails." \
    '. += [{ "title": $title, "details": $details, "severity": $severity, "next_steps": $next_steps }]')
  echo "$issues_json" > "$ISSUES_JSON"
  echo "[]" > "$OUTPUT_JSON"
  exit 0
fi

if ! raw=$(az network nsg show -g "$RG" -n "$NSG_NAME" --subscription "$AZURE_SUBSCRIPTION_ID" -o json 2>err.log); then
  err_msg=$(cat err.log || true)
  rm -f err.log
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Failed to read NSG \`$NSG_NAME\`" \
    --arg details "Azure CLI error: $err_msg" \
    --argjson severity 4 \
    --arg next_steps "Confirm Reader access on the NSG and subscription context." \
    '. += [{ "title": $title, "details": $details, "severity": $severity, "next_steps": $next_steps }]')
  echo "$issues_json" > "$ISSUES_JSON"
  echo "[]" > "$OUTPUT_JSON"
  exit 0
fi
rm -f err.log

NSG_ID=$(echo "$raw" | jq -r '.id')

# Subnets linked to this NSG (references under properties.subnets from Azure CLI / ARM)
SUBNET_IDS=$(echo "$raw" | jq -c '[(.properties.subnets // [])[]?.id // empty] | unique')

# NICs in RG referencing this NSG
NIC_IDS='[]'
if NIC_JSON=$(az network nic list -g "$RG" --subscription "$AZURE_SUBSCRIPTION_ID" -o json 2>/dev/null); then
  NIC_IDS=$(echo "$NIC_JSON" | jq --arg id "$NSG_ID" \
    '[.[] | select(.networkSecurityGroup != null and .networkSecurityGroup.id == $id) | .id] | unique')
fi

# Normalize rules for stable comparison (sort arrays, order rules by priority then name)
normalized=$(echo "$raw" | jq --arg schemaVersion "1" \
  --argjson subnetIds "$SUBNET_IDS" --argjson nicIds "$NIC_IDS" '
  {
    schemaVersion: $schemaVersion,
    subscriptionId: (.id | split("/")[2] // ""),
    resourceGroup: (.resourceGroup // ""),
    nsgName: .name,
    resourceId: .id,
    location: .location,
    securityRules: (
      [.properties.securityRules[]?] | map({
        name: .name,
        id: .id,
        priority: .properties.priority,
        direction: .properties.direction,
        access: .properties.access,
        protocol: .properties.protocol,
        provisioningState: .properties.provisioningState,
        description: (.properties.description // ""),
        sourcePortRange: (.properties.sourcePortRange // ""),
        sourcePortRanges: ((.properties.sourcePortRanges // []) | sort),
        destinationPortRange: (.properties.destinationPortRange // ""),
        destinationPortRanges: ((.properties.destinationPortRanges // []) | sort),
        sourceAddressPrefix: (.properties.sourceAddressPrefix // ""),
        sourceAddressPrefixes: ((.properties.sourceAddressPrefixes // []) | sort),
        destinationAddressPrefix: (.properties.destinationAddressPrefix // ""),
        destinationAddressPrefixes: ((.properties.destinationAddressPrefixes // []) | sort),
        sourceApplicationSecurityGroups: ((.properties.sourceApplicationSecurityGroups // []) | map(.id) | sort),
        destinationApplicationSecurityGroups: ((.properties.destinationApplicationSecurityGroups // []) | map(.id) | sort)
      }) | sort_by(.priority, .name)
    ),
    defaultSecurityRules: (
      [.properties.defaultSecurityRules[]?] | map({
        name: .name,
        priority: .properties.priority,
        direction: .properties.direction,
        access: .properties.access,
        protocol: .properties.protocol,
        sourcePortRange: (.properties.sourcePortRange // ""),
        destinationPortRange: (.properties.destinationPortRange // ""),
        sourceAddressPrefix: (.properties.sourceAddressPrefix // ""),
        destinationAddressPrefix: (.properties.destinationAddressPrefix // "")
      }) | sort_by(.priority, .name)
    ),
    associations: {
      subnetIds: $subnetIds,
      networkInterfaceIds: $nicIds
    }
  }
')

echo "$normalized" | jq . > "$OUTPUT_JSON"
echo "$issues_json" | jq . > "$ISSUES_JSON"
echo "Exported live NSG state to $OUTPUT_JSON"
