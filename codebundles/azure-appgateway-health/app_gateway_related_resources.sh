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
#   1) Fetches the App Gateway configuration via `az network application-gateway show`
#   2) For each backendAddressPool -> .backendAddresses[] -> .fqdn or .ipAddress
#   3) Attempts to find an Azure resource that matches that address:
#       - If IP => check if any VM has that IP
#       - If ends with .azurewebsites.net => check for an App Service
#       - If ends with .azurecontainer.io => check Container Instances
#       - If ends with .hcp.*.azmk8s.io => check AKS
#       - Otherwise, store "Unknown" or no resource found
#   4) Produces a JSON map of { "discoveries": [ { "address": "xx", "resource_type": "...", "resource_id": "..." }, ... ] }
# -----------------------------------------------------------------------------

: "${APP_GATEWAY_NAME:?Must set APP_GATEWAY_NAME}"
: "${AZ_RESOURCE_GROUP:?Must set AZ_RESOURCE_GROUP}"

OUTPUT_DIR="${OUTPUT_DIR:-./output}"
mkdir -p "$OUTPUT_DIR"
OUTPUT_FILE="${OUTPUT_DIR}/appgw_resource_discovery.json"

echo "Finding related Azure resources for backend pool addresses in App Gateway \`$APP_GATEWAY_NAME\` (RG: \`$AZ_RESOURCE_GROUP\`)..."
echo "Output file: $OUTPUT_FILE"

discoveries='{"discoveries": []}'

# 1) Get the App Gateway config
echo "Retrieving App Gateway config..."
if ! appgw_json=$(az network application-gateway show \
      --name "$APP_GATEWAY_NAME" \
      --resource-group "$AZ_RESOURCE_GROUP" \
      -o json 2>$OUTPUT_DIR/appgw_show_err.log); then
  echo "ERROR: Could not retrieve App Gateway JSON."
  error_txt=$(cat $OUTPUT_DIR/appgw_show_err.log)
  rm -f $OUTPUT_DIR/appgw_show_err.log

  discoveries=$(echo "$discoveries" | jq \
    --arg msg "Failed to fetch App Gateway config: $error_txt" \
    '.discoveries += [ { "error": $msg } ]')
  echo "$discoveries" > "$OUTPUT_FILE"
  exit 1
fi
rm -f $OUTPUT_DIR/appgw_show_err.log

# 2) Parse all backend addresses
backend_pools=$(echo "$appgw_json" | jq -r '.backendAddressPools[]? | @base64')
if [[ -z "$backend_pools" ]]; then
  echo "No backend pools found."
  discoveries=$(echo "$discoveries" | jq \
    '.discoveries += [{ "info": "No backend pools configured" }]')
  echo "$discoveries" > "$OUTPUT_FILE"
  exit 0
fi

# Helper function to attempt resource lookups
lookup_resource() {
  local address="$1"

  # Default
  local resource_type="Unknown"
  local resource_id=""
  local resource_group_found=""

  # Check patterns
  if [[ "$address" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    # IP => check VM
    # Attempt to find VM by IP
    local vm_id
    vm_id=$(az vm list-ip-addresses --query "[?ipAddress=='$address'].virtualMachine.id" -o tsv 2>/dev/null || true)
    if [[ -n "$vm_id" ]]; then
      resource_type="VirtualMachine"
      resource_id="$vm_id"
    fi
  elif [[ "$address" == *.azurewebsites.net ]]; then
    # App Service
    local app_service_json
    app_service_json=$(az webapp list --query "[?defaultHostName=='$address'] | [0]" -o json 2>/dev/null || true)
    if [[ -n "$app_service_json" && "$app_service_json" != "null" ]]; then
      resource_type="AppService"
      resource_id=$(echo "$app_service_json" | jq -r '.id // empty')
    fi
  elif [[ "$address" == *.azurecontainer.io ]]; then
    # Container Instance
    local container_id
    container_id=$(az container list --query "[?contains(ipAddress.fqdn, '$address')].id" -o tsv 2>/dev/null || true)
    if [[ -n "$container_id" ]]; then
      resource_type="ContainerInstance"
      resource_id="$container_id"
    fi
  elif [[ "$address" == *.hcp.*.azmk8s.io ]]; then
    # AKS
    local aks_id
    aks_id=$(az aks list --query "[?contains(fqdn, '$address')].id" -o tsv 2>/dev/null || true)
    if [[ -n "$aks_id" ]]; then
      resource_type="AKS"
      resource_id="$aks_id"
    fi
  else
    # Some other FQDN or pattern
    resource_type="CustomFQDNOrExternal"
  fi

  # Return JSON snippet
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

# Iterate each pool
while IFS= read -r pool_encoded; do
  pool_decoded=$(echo "$pool_encoded" | base64 --decode)
  pool_name=$(echo "$pool_decoded" | jq -r '.name')
  addresses=$(echo "$pool_decoded" | jq -c '.backendAddresses[]?')
  if [[ -z "$addresses" ]]; then
    continue
  fi

  echo "Checking addresses in backend pool: $pool_name"

  while IFS= read -r addr_json; do
    # Could be .fqdn or .ipAddress
    # We'll unify them into a single variable called "address"
    address_val=$(echo "$addr_json" | jq -r '(.fqdn // .ipAddress) // empty')

    if [[ -z "$address_val" ]]; then
      continue
    fi

    echo "Address: $address_val -> looking up potential Azure resource..."

    lookup_result=$(lookup_resource "$address_val")

    # Merge into discoveries
    discoveries=$(echo "$discoveries" | jq \
      --argjson lr "$lookup_result" \
      --arg pool "$pool_name" \
      '.discoveries += [ $lr + { "backendPoolName": $pool } ]')
  done <<< "$(echo "$addresses")"

done <<< "$backend_pools"

# Output final JSON
echo "Related Resource Discovery completed. Writing results to $OUTPUT_FILE"
echo "$discoveries" | jq . > "$OUTPUT_FILE"
