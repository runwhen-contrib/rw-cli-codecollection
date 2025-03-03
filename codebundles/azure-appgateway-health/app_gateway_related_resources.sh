#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# ENVIRONMENT VARIABLES REQUIRED:
#   APP_GATEWAY_NAME
#   AZ_RESOURCE_GROUP
#
# OPTIONAL:
#   OUTPUT_DIR (default: ./output)
#
# This script:
#   1) Fetches the App Gateway configuration -> finds references
#       - Subnets, Public IPs, WAF policy, user-assigned identities
#       - Backend pools -> addresses -> possible Azure resources
#   2) Discovers each subnet -> NSGs, route tables, and now the PARENT VNET
#   3) Second pass: for discovered resources like VMs, App Services, we fetch
#      additional network details (NICs, Private Endpoints, etc.)
#   4) Produces a JSON array of "discoveries" with:
#       - resource_id
#       - resource_type
#       - referenceType (context of how it was found)
#       - resource_url (Azure portal link)
# -----------------------------------------------------------------------------

: "${APP_GATEWAY_NAME:?Must set APP_GATEWAY_NAME}"
: "${AZ_RESOURCE_GROUP:?Must set AZ_RESOURCE_GROUP}"

OUTPUT_DIR="${OUTPUT_DIR:-./output}"
mkdir -p "$OUTPUT_DIR"
OUTPUT_FILE="${OUTPUT_DIR}/appgw_resource_discovery.json"

echo "Finding related Azure resources for App Gateway ‘$APP_GATEWAY_NAME’ (RG: ‘$AZ_RESOURCE_GROUP’)..."
echo "Output file: $OUTPUT_FILE"

# A JSON structure to accumulate final results
discoveries='{"discoveries": []}'

append_discovery() {
  local discovery_json="$1"
  discoveries=$(echo "$discoveries" | jq \
    --argjson disc "$discovery_json" \
    '.discoveries += [$disc]')
}

# Function to guess a resource type from an Azure resource ID
infer_resource_type_from_id() {
  local rid="$1"
  local inferred="Unknown"

  if [[ "$rid" == *"/subnets/"* ]]; then
    inferred="Subnet"
  elif [[ "$rid" == *"/publicIPAddresses/"* ]]; then
    inferred="PublicIPAddress"
  elif [[ "$rid" == *"/firewallPolicies/"* ]]; then
    inferred="FirewallPolicy"
  elif [[ "$rid" == *"/userAssignedIdentities/"* ]]; then
    inferred="UserAssignedIdentity"
  elif [[ "$rid" == *"/networkSecurityGroups/"* ]]; then
    inferred="NetworkSecurityGroup"
  elif [[ "$rid" == *"/routeTables/"* ]]; then
    inferred="RouteTable"
  elif [[ "$rid" == *"/applicationGateways/"* ]]; then
    inferred="ApplicationGateway"
  elif [[ "$rid" == *"/virtualMachines/"* ]]; then
    inferred="VirtualMachine"
  elif [[ "$rid" == *"/sites/"* ]]; then
    # "sites" is the resource type for Web Apps
    inferred="AppService"
  elif [[ "$rid" == *"/virtualNetworks/"* ]]; then
    inferred="VirtualNetwork"
  elif [[ "$rid" == *"/networkInterfaces/"* ]]; then
    inferred="NetworkInterface"
  fi

  echo "$inferred"
}

# Builds a minimal JSON snippet for a discovered resource ID
build_discovery_json() {
  local resource_id="$1"
  local reference_type="$2"  # e.g. "gatewaySubnet", "vmNic", etc.

  local rtype
  rtype="$(infer_resource_type_from_id "$resource_id")"

  jq -n \
    --arg rid "$resource_id" \
    --arg rtype "$rtype" \
    --arg refType "$reference_type" \
    '{
      "resource_id": $rid,
      "resource_type": $rtype,
      "referenceType": $refType
    }'
}

append_appgw_reference() {
  local resourceId="$1"
  local referenceType="$2"

  if [[ -z "$resourceId" ]]; then
    return
  fi

  local snippet
  snippet=$(build_discovery_json "$resourceId" "$referenceType")
  append_discovery "$snippet"
}

# 1) Retrieve the App Gateway config
echo "Retrieving App Gateway config..."
if ! appgw_json=$(az network application-gateway show \
      --name "$APP_GATEWAY_NAME" \
      --resource-group "$AZ_RESOURCE_GROUP" \
      -o json 2>$OUTPUT_DIR/appgw_show_err.log); then
  echo "ERROR: Could not retrieve App Gateway JSON."
  error_txt=$(cat "$OUTPUT_DIR/appgw_show_err.log")
  rm -f "$OUTPUT_DIR/appgw_show_err.log"

  discoveries=$(echo "$discoveries" | jq \
    --arg msg "Failed to fetch App Gateway config: $error_txt" \
    '.discoveries += [ { "error": $msg } ]')
  echo "$discoveries" > "$OUTPUT_FILE"
  exit 1
fi
rm -f "$OUTPUT_DIR/appgw_show_err.log"

# 2) Collect references from the App Gateway
echo "Collecting direct references from the App Gateway..."

# 2a) The App Gateway's own ID
appgw_id=$(echo "$appgw_json" | jq -r '.id // empty')
append_appgw_reference "$appgw_id" "appGatewayResource"

# 2b) Gateway IP configurations => subnets
# (Check .gatewayIpConfigurations and .gatewayIPConfigurations, just in case)
gateway_subnet_ids=$(echo "$appgw_json" | jq -r '
  (
    .gatewayIpConfigurations[]?.subnet.id?,
    .gatewayIPConfigurations[]?.subnet.id?
  ) // empty
')

while IFS= read -r sid; do
  append_appgw_reference "$sid" "gatewayIpConfiguration.subnet"
done <<< "$gateway_subnet_ids"

# 2c) Frontend IP configs => publicIP or subnet
frontend_publicip_ids=$(echo "$appgw_json" | jq -r '.frontendIPConfigurations[]?.publicIpAddress.id // empty')
while IFS= read -r pid; do
  append_appgw_reference "$pid" "frontendIpConfiguration.publicIpAddress"
done <<< "$frontend_publicip_ids"

frontend_subnet_ids=$(echo "$appgw_json" | jq -r '.frontendIPConfigurations[]?.subnet.id // empty')
while IFS= read -r sid; do
  append_appgw_reference "$sid" "frontendIpConfiguration.subnet"
done <<< "$frontend_subnet_ids"

# 2d) WAF policy
firewall_policy_id=$(echo "$appgw_json" | jq -r '.webApplicationFirewallConfiguration.firewallPolicy.id // empty')
append_appgw_reference "$firewall_policy_id" "webApplicationFirewallPolicy"

# 2e) User-assigned identities (if present)
user_assigned_ids=$(echo "$appgw_json" | jq -r '
  if .identity.userAssignedIdentities? != null then
    .identity.userAssignedIdentities | keys[]
  else
    empty
  end
')
while IFS= read -r uai_id; do
  append_appgw_reference "$uai_id" "userAssignedIdentity"
done <<< "$user_assigned_ids"

# 3) For each discovered subnet, see if it has an NSG / route table and ALSO capture its parent VNet
echo "Discovering attached NSGs/RouteTables, plus parent VNet, for subnets..."

subnet_ids=$(echo "$discoveries" | jq -r '
  .discoveries[]
  | select(.resource_type == "Subnet")
  | .resource_id
  ' | sort -u)

processed_subnets=()

for sid in $subnet_ids; do
  if [[ " ${processed_subnets[*]} " =~ " $sid " ]]; then
    # Already processed
    continue
  fi
  processed_subnets+=("$sid")

  echo "  Checking subnet: $sid"
  if ! subnet_info=$(az network vnet subnet show --ids "$sid" -o json 2>/dev/null); then
    echo "    Could not retrieve details for subnet."
    continue
  fi

  # Check if NSG attached
  nsg_id=$(echo "$subnet_info" | jq -r '.networkSecurityGroup.id // empty')
  if [[ -n "$nsg_id" ]]; then
    echo "    Found attached NSG: $nsg_id"
    snippet=$(build_discovery_json "$nsg_id" "subnetAttachedNsg")
    append_discovery "$snippet"
  fi

  # Check if route table attached
  route_table_id=$(echo "$subnet_info" | jq -r '.routeTable.id // empty')
  if [[ -n "$route_table_id" ]]; then
    echo "    Found attached routeTable: $route_table_id"
    snippet=$(build_discovery_json "$route_table_id" "subnetAttachedRouteTable")
    append_discovery "$snippet"
  fi

  # **NEW**: Parse out the Parent VNet ID from the subnet ID
  # e.g. /subscriptions/.../virtualNetworks/myVNet/subnets/mySubnet
  # becomes /subscriptions/.../virtualNetworks/myVNet
  vnet_id="$(echo "$sid" | sed 's|/subnets/.*||')"
  echo "    Parent VNet for this subnet is: $vnet_id"
  snippet=$(build_discovery_json "$vnet_id" "subnetParentVnet")
  append_discovery "$snippet"
done

# 4) Parse all backend addresses and attempt resource lookups
echo "Extracting backend addresses from backend pools..."

backend_pools=$(echo "$appgw_json" | jq -r '.backendAddressPools[]? | @base64')
if [[ -z "$backend_pools" ]]; then
  echo "No backend pools found."
else
  lookup_resource() {
    local address="$1"
    local resource_type="Unknown"
    local resource_id=""

    # IP pattern?
    if [[ "$address" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      # Attempt to find VM by IP
      local vm_id
      vm_id=$(az vm list-ip-addresses --query "[?ipAddress=='$address'].virtualMachine.id" -o tsv 2>/dev/null || true)
      if [[ -n "$vm_id" ]]; then
        resource_type="VirtualMachine"
        resource_id="$vm_id"
      fi

    # App Service pattern?
    elif [[ "$address" == *.azurewebsites.net ]]; then
      local app_service_json
      app_service_json=$(az webapp list --query "[?defaultHostName=='$address'] | [0]" -o json 2>/dev/null || true)
      if [[ -n "$app_service_json" && "$app_service_json" != "null" ]]; then
        resource_type="AppService"
        resource_id=$(echo "$app_service_json" | jq -r '.id // empty')
      fi

    # Container Instances pattern?
    elif [[ "$address" == *.azurecontainer.io ]]; then
      local container_id
      container_id=$(az container list --query "[?contains(ipAddress.fqdn, '$address')].id" -o tsv 2>/dev/null || true)
      if [[ -n "$container_id" ]]; then
        resource_type="ContainerInstance"
        resource_id="$container_id"
      fi

    # AKS pattern?
    elif [[ "$address" == *.hcp.*.azmk8s.io ]]; then
      local aks_id
      aks_id=$(az aks list --query "[?contains(fqdn, '$address')].id" -o tsv 2>/dev/null || true)
      if [[ -n "$aks_id" ]]; then
        resource_type="AKS"
        resource_id="$aks_id"
      fi

    else
      resource_type="CustomFQDNOrExternal"
    fi

    jq -n \
      --arg address "$address" \
      --arg rtype "$resource_type" \
      --arg rid "$resource_id" \
      '{
        "address": $address,
        "resource_type": $rtype,
        "resource_id": $rid
      }'
  }

  while IFS= read -r pool_encoded; do
    pool_decoded=$(echo "$pool_encoded" | base64 --decode)
    pool_name=$(echo "$pool_decoded" | jq -r '.name')
    addresses=$(echo "$pool_decoded" | jq -c '.backendAddresses[]?')
    if [[ -z "$addresses" ]]; then
      continue
    fi

    echo "  Checking addresses in backend pool: $pool_name"
    while IFS= read -r addr_json; do
      address_val=$(echo "$addr_json" | jq -r '(.fqdn // .ipAddress) // empty')
      if [[ -z "$address_val" ]]; then
        continue
      fi

      echo "    Address: $address_val -> looking up potential Azure resource..."
      lookup_result=$(lookup_resource "$address_val")
      # Append "backendPoolName" into the discovered item
      resource_snippet=$(echo "$lookup_result" | jq \
        --arg pool "$pool_name" \
        '. + { "backendPoolName": $pool }')
      discoveries=$(echo "$discoveries" | jq \
        --argjson lr "$resource_snippet" \
        '.discoveries += [ $lr ]')
    done <<< "$(echo "$addresses")"
  done <<< "$backend_pools"
fi

# 5) SECOND PASS: Drill into known resource types for their networking references
#    - We'll demonstrate for VirtualMachine and AppService. You can add more if you like.

echo "Drilling deeper into discovered resources for more network references..."

to_drill=$(echo "$discoveries" | jq -r '
  .discoveries[]
  | select(.resource_id != null and .resource_id != "")
  | { resource_id, resource_type }
  | @base64
')

processed_ids=()  # keep track to avoid duplicates

while IFS= read -r enc; do
  item=$(echo "$enc" | base64 --decode)
  rid=$(echo "$item" | jq -r '.resource_id')
  rtype=$(echo "$item" | jq -r '.resource_type')

  # Skip if already processed
  if [[ " ${processed_ids[*]} " =~ " $rid " ]]; then
    continue
  fi
  processed_ids+=("$rid")

  case "$rtype" in
    "VirtualMachine")
      echo "  Drilling into VM: $rid"
      # 5a) Retrieve the VM => find NIC references
      if vm_json=$(az vm show --ids "$rid" -o json 2>/dev/null); then
        nic_ids=$(echo "$vm_json" | jq -r '.networkProfile.networkInterfaces[]?.id // empty')
        for nic_id in $nic_ids; do
          echo "    Found NIC: $nic_id"
          snippet=$(build_discovery_json "$nic_id" "vmNic")
          append_discovery "$snippet"

          # 5b) For each NIC, discover subnets, NSG, public IP, etc.
          if nic_json=$(az network nic show --ids "$nic_id" -o json 2>/dev/null); then
            # Subnets
            nic_subnets=$(echo "$nic_json" | jq -r '.ipConfigurations[]?.subnet.id // empty')
            for nsid in $nic_subnets; do
              echo "      NIC Subnet: $nsid"
              snippet=$(build_discovery_json "$nsid" "nicSubnet")
              append_discovery "$snippet"
            done

            # Attached NSG
            nic_nsg_id=$(echo "$nic_json" | jq -r '.networkSecurityGroup.id // empty')
            if [[ -n "$nic_nsg_id" ]]; then
              echo "      NIC-level NSG: $nic_nsg_id"
              snippet=$(build_discovery_json "$nic_nsg_id" "nicNsg")
              append_discovery "$snippet"
            fi

            # Public IP?
            nic_pip_ids=$(echo "$nic_json" | jq -r '.ipConfigurations[]?.publicIpAddress.id // empty')
            for pipid in $nic_pip_ids; do
              echo "      NIC-level Public IP: $pipid"
              snippet=$(build_discovery_json "$pipid" "nicPublicIp")
              append_discovery "$snippet"
            done
          fi
        done
      else
        echo "    Could not retrieve VM details."
      fi
      ;;
    "AppService")
      echo "  Drilling into App Service: $rid"
      # 5c) Retrieve the App Service => check for possible private endpoints, etc.
      if app_json=$(az webapp show --ids "$rid" -o json 2>/dev/null); then
        # Example: look for private endpoints referencing this resource:
        pe_json=$(az network private-endpoint list --query "[?privateLinkServiceId=='$rid']" -o json 2>/dev/null || true)
        if [[ -n "$pe_json" && "$pe_json" != "[]" ]]; then
          echo "$pe_json" | jq -c '.[]' | while read -r pe; do
            pe_id=$(echo "$pe" | jq -r '.id // empty')
            if [[ -n "$pe_id" ]]; then
              echo "    Found Private Endpoint: $pe_id"
              snippet=$(build_discovery_json "$pe_id" "appServicePrivateEndpoint")
              append_discovery "$snippet"

              # Also parse the endpoint's subnet
              pe_subnet_id=$(echo "$pe" | jq -r '.subnet.id // empty')
              if [[ -n "$pe_subnet_id" ]]; then
                echo "      Private Endpoint Subnet: $pe_subnet_id"
                snippet=$(build_discovery_json "$pe_subnet_id" "privateEndpointSubnet")
                append_discovery "$snippet"
              fi
            fi
          done
        fi
      fi
      ;;
    # Optional: add more expansions for ContainerInstance, AKS, etc.
  esac
done <<< "$to_drill"

# 6) Add a portal URL for any discovered resource_id
discoveries=$(echo "$discoveries" | jq '
  .discoveries |= map(
    if (.resource_id | length) > 0 then
      . + { "resource_url": ("https://portal.azure.com/#view/HubsExtension/ResourceBlade/resourceId" + .resource_id) }
    else
      .
    end
  )
')

echo "Related Resource Discovery completed. Writing results to $OUTPUT_FILE"
echo "$discoveries" | jq . > "$OUTPUT_FILE"
