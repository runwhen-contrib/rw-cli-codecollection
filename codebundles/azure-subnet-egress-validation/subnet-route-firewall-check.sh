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
#   REQUIRE_DEFAULT_ROUTE_VIA_FIREWALL  true|false (default false)
#
# Outputs: subnet_route_issues.json
# -----------------------------------------------------------------------------

: "${AZURE_SUBSCRIPTION_ID:?Must set AZURE_SUBSCRIPTION_ID}"
: "${AZURE_RESOURCE_GROUP:?Must set AZURE_RESOURCE_GROUP}"
: "${VNET_NAME:?Must set VNET_NAME}"

OUTPUT_ISSUES="subnet_route_issues.json"
DISCOVERY="discovered_subnets.json"
REQUIRE_FW=${REQUIRE_DEFAULT_ROUTE_VIA_FIREWALL:-false}
issues_json='[]'

az account set --subscription "${AZURE_SUBSCRIPTION_ID}" >/dev/null 2>&1 || true

if [[ -f "$DISCOVERY" ]]; then
  subnets=$(cat "$DISCOVERY")
else
  subnets=$(az network vnet subnet list \
    --resource-group "${AZURE_RESOURCE_GROUP}" \
    --vnet-name "${VNET_NAME}" \
    -o json | jq '[.[] | {name: .name, id: .id, routeTable: .routeTable}]')
fi

extract_rg_from_id() {
  echo "$1" | awk -F/ '{print $5}'
}

extract_name_from_id() {
  echo "$1" | awk -F/ '{print $9}'
}

check_routes_for_subnet() {
  local sname="$1"
  local rt_id="$2"
  local rt_rg rt_name routes_json
  rt_rg=$(extract_rg_from_id "$rt_id")
  rt_name=$(extract_name_from_id "$rt_id")
  if ! routes_json=$(az network route-table route list \
    --resource-group "$rt_rg" \
    --route-table-name "$rt_name" \
    -o json 2>err_rt.log); then
    err_msg=$(cat err_rt.log 2>/dev/null || echo "error")
    rm -f err_rt.log
    issues_json=$(echo "$issues_json" | jq \
      --arg title "Cannot Read Routes for Subnet \`${sname}\`" \
      --arg details "route list failed for table $rt_name: $err_msg" \
      --arg severity "3" \
      --arg next_steps "Verify permissions on route table $rt_name and resource group $rt_rg." \
      '. += [{
         "title": $title,
         "details": $details,
         "severity": ($severity | tonumber),
         "next_steps": $next_steps
       }]')
    return
  fi
  rm -f err_rt.log

  if [[ "${REQUIRE_FW}" == "true" ]]; then
    local has_va
    has_va=$(echo "$routes_json" | jq '[.[] | select(.addressPrefix=="0.0.0.0/0" and (.nextHopType=="VirtualAppliance" or .nextHopType=="Firewall"))] | length')
    if [[ "$has_va" -eq 0 ]]; then
      issues_json=$(echo "$issues_json" | jq \
        --arg title "Missing Required Default Route via Firewall/NVA for Subnet \`${sname}\`" \
        --arg details "REQUIRE_DEFAULT_ROUTE_VIA_FIREWALL=true but no 0.0.0.0/0 route with nextHopType VirtualAppliance or Firewall on route table \`$rt_name\`." \
        --arg severity "4" \
        --arg next_steps "Add a UDR for 0.0.0.0/0 pointing to your Azure Firewall private IP (VirtualAppliance) or required NVA; associate the route table with the subnet." \
        '. += [{
           "title": $title,
           "details": $details,
           "severity": ($severity | tonumber),
           "next_steps": $next_steps
         }]')
    fi
  fi
}

while IFS= read -r row; do
  sname=$(echo "$row" | jq -r '.name')
  rt_id=$(echo "$row" | jq -r '.routeTable.id // empty')
  if [[ -z "$rt_id" || "$rt_id" == "null" ]]; then
    issues_json=$(echo "$issues_json" | jq \
      --arg title "Subnet \`${sname}\` Has No Route Table" \
      --arg details "No custom route table associated; effective routes follow Azure system routes only." \
      --arg severity "2" \
      --arg next_steps "Associate a route table if policy requires UDR-based egress via firewall or hybrid connectivity." \
      '. += [{
         "title": $title,
         "details": $details,
         "severity": ($severity | tonumber),
         "next_steps": $next_steps
       }]')
    continue
  fi
  check_routes_for_subnet "$sname" "$rt_id"
done < <(echo "$subnets" | jq -c '.[]')

echo "$issues_json" > "$OUTPUT_ISSUES"
echo "Route / firewall next-hop check written to $OUTPUT_ISSUES"
