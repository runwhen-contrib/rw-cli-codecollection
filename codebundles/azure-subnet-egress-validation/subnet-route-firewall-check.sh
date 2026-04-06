#!/usr/bin/env bash
# Validates UDRs for default route (0.0.0.0/0) and presence of Azure Firewall in the RG.
# Writes subnet_route_issues.json and subnet_route_summary.json
set -euo pipefail
set -x

: "${AZURE_SUBSCRIPTION_ID:?Must set AZURE_SUBSCRIPTION_ID}"
: "${AZURE_RESOURCE_GROUP:?Must set AZURE_RESOURCE_GROUP}"
: "${VNET_NAME:?Must set VNET_NAME}"

OUTPUT_FILE="subnet_route_issues.json"
SUMMARY_JSON="subnet_route_summary.json"
issues_json='[]'
summary='[]'

az account set --subscription "$AZURE_SUBSCRIPTION_ID" 2>/dev/null || true

firewall_ids=$(az network firewall list \
  --resource-group "$AZURE_RESOURCE_GROUP" \
  --subscription "$AZURE_SUBSCRIPTION_ID" \
  --query "[].id" -o tsv 2>/dev/null || true)
if [ -n "${firewall_ids//[$'\t\r\n']/}" ]; then
  fw_count=$(echo "$firewall_ids" | wc -l)
else
  fw_count=0
fi

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

  rt_id=$(echo "$sub_json" | jq -r '.routeTable.id // ""')
  if [ -n "$rt_id" ] && [ "$rt_id" != "null" ]; then
    has_rt_json=true
  else
    has_rt_json=false
  fi
  entry=$(jq -n \
    --arg subnet "$sn" \
    --arg rt "$rt_id" \
    --argjson hasRt "$has_rt_json" \
    '{subnetName: $subnet, routeTableId: $rt, hasRouteTable: $hasRt}')

  if [ -z "$rt_id" ] || [ "$rt_id" = "null" ]; then
    if [ "${fw_count:-0}" -gt 0 ]; then
      issues_json=$(echo "$issues_json" | jq \
        --arg title "Subnet \`$sn\` has no route table while Azure Firewall exists in \`$AZURE_RESOURCE_GROUP\`" \
        --arg details "Forced tunneling through Azure Firewall typically requires a UDR on the subnet with 0.0.0.0/0 -> VirtualAppliance (firewall private IP)." \
        --arg severity "3" \
        --arg next_steps "Attach a route table with default route pointing to the firewall private IP, or confirm hub/spoke design routes traffic elsewhere." \
        '. += [{
          "title": $title,
          "details": $details,
          "severity": ($severity | tonumber),
          "next_steps": $next_steps
        }]')
    fi
    summary=$(echo "$summary" | jq --argjson e "$entry" '. += [$e]')
    continue
  fi

  rt_name=$(basename "$rt_id")
  rt_rg=$(echo "$rt_id" | sed -n 's|.*/resourceGroups/\([^/]*\)/providers/.*|\1|p')
  [ -z "$rt_rg" ] && rt_rg="$AZURE_RESOURCE_GROUP"

  routes_json=$(az network route-table route list \
    --resource-group "$rt_rg" \
    --route-table-name "$rt_name" \
    --subscription "$AZURE_SUBSCRIPTION_ID" \
    -o json 2>/dev/null || echo "[]")

  default_route=$(echo "$routes_json" | jq '[.[] | select((.addressPrefix // "") | test("^0\\.0\\.0\\.0/0$"))] | .[0] // empty')
  next_hop=$(echo "$default_route" | jq -r '.nextHopType // empty')
  next_hop_ip=$(echo "$default_route" | jq -r '.nextHopIpAddress // empty')

  entry=$(echo "$entry" | jq \
    --arg nh "$next_hop" \
    --arg ip "$next_hop_ip" \
    '. + {defaultRouteNextHopType: $nh, defaultRouteNextHopIp: $ip}')
  summary=$(echo "$summary" | jq --argjson e "$entry" '. += [$e]')

  if [ -n "$default_route" ] && [ "$next_hop" = "Internet" ] && [ "${fw_count:-0}" -gt 0 ]; then
    issues_json=$(echo "$issues_json" | jq \
      --arg title "Subnet \`$sn\` default route uses Internet next hop while Azure Firewall exists" \
      --arg details "Default route 0.0.0.0/0 points to Internet instead of VirtualAppliance/firewall. Egress may bypass Azure Firewall policies." \
      --arg severity "4" \
      --arg next_steps "Change the default route next hop to VirtualAppliance with the firewall private IP, or move the subnet behind a hub VNet with correct UDRs." \
      '. += [{
        "title": $title,
        "details": $details,
        "severity": ($severity | tonumber),
        "next_steps": $next_steps
      }]')
  fi

  if [ -z "$default_route" ] && [ "${fw_count:-0}" -gt 0 ]; then
    issues_json=$(echo "$issues_json" | jq \
      --arg title "Subnet \`$sn\` route table has no 0.0.0.0/0 route while Azure Firewall exists" \
      --arg details "Without an explicit default route, traffic may follow system routes (often direct Internet from Azure) and not through the firewall." \
      --arg severity "3" \
      --arg next_steps "Add UDR 0.0.0.0/0 with next hop VirtualAppliance to the firewall IP if policy requires centralized egress." \
      '. += [{
        "title": $title,
        "details": $details,
        "severity": ($severity | tonumber),
        "next_steps": $next_steps
      }]')
  fi
done <<< "$subnet_names"

echo "$summary" > "$SUMMARY_JSON"
echo "$issues_json" > "$OUTPUT_FILE"

echo "Route / firewall summary:"
echo "$summary" | jq .
echo "Issues written to $OUTPUT_FILE"
