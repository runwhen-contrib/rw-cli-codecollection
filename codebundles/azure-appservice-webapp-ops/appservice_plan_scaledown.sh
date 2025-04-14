#!/usr/bin/env bash
#
# scale_down_appservice.sh
#
# This script automatically scales an Azure App Service to a lower (less expensive)
# tier based on its current SKU. For example:
#   S3 -> S2, S2 -> S1, S1 -> B3, B3 -> B2, etc.
#
# Environment variables required:
#   AZ_RESOURCE_GROUP  - Name of the Azure resource group
#   APP_SERVICE_NAME   - Name of the Azure App Service
#
# Optional:
#   SKU_DOWN_MAP_JSON  - JSON dictionary of currentSKU -> nextLowerSKU. If not set,
#                       a default map is used. Adjust it for your environment.
#
# Usage example:
#   export AZ_RESOURCE_GROUP="MyRG"
#   export APP_SERVICE_NAME="MyAppService"
#   bash scale_down_appservice.sh
#
#   # Or provide a custom mapping:
#   export SKU_DOWN_MAP_JSON='{"S2":"S1","S1":"B3","B3":"B2"}'
#   bash scale_down_appservice.sh
#

set -euo pipefail

##############################################################################
# 1) Validate environment
##############################################################################
: "${AZ_RESOURCE_GROUP:?Must set AZ_RESOURCE_GROUP}"
: "${APP_SERVICE_NAME:?Must set APP_SERVICE_NAME}"

# Default mapping if SKU_DOWN_MAP_JSON not provided externally
DEFAULT_DOWN_MAP='{
  "P3v2": "P2v2",
  "P2v2": "P1v2",
  "P1v2": "S3",
  "S3":   "S2",
  "S2":   "S1",
  "S1":   "B3",
  "B3":   "B2",
  "B2":   "B1",
  "B1":   "F1"
}'

SKU_DOWN_MAP_JSON="${SKU_DOWN_MAP_JSON:-$DEFAULT_DOWN_MAP}"

##############################################################################
# 2) Retrieve the current App Service Plan and SKU
##############################################################################
echo "Retrieving current App Service Plan for '${APP_SERVICE_NAME}' in '${AZ_RESOURCE_GROUP}'..."
app_info_json="$(az webapp show \
  --resource-group "${AZ_RESOURCE_GROUP}" \
  --name "${APP_SERVICE_NAME}" \
  --output json \
  2>/dev/null || true)"

if [[ -z "$app_info_json" || "$app_info_json" == "null" ]]; then
  echo "ERROR: Could not retrieve info for App Service '${APP_SERVICE_NAME}'."
  echo "Check that it exists and you have the correct resource group."
  exit 1
fi

# Some apps have .serverFarmId, others have .appServicePlanId
server_farm_id="$(echo "$app_info_json" | jq -r '.serverFarmId // .appServicePlanId // empty')"
if [[ -z "$server_farm_id" ]]; then
  echo "ERROR: Neither 'serverFarmId' nor 'appServicePlanId' found in app data!"
  echo "Raw webapp JSON was:"
  echo "$app_info_json"
  exit 1
fi

plan_name="$(basename "$server_farm_id")"

echo "Current Plan Name: $plan_name"

# Now fetch the plan details to see the current SKU
plan_info_json="$(az appservice plan show \
  --name "$plan_name" \
  --resource-group "${AZ_RESOURCE_GROUP}" \
  --output json \
  2>/dev/null || true)"

if [[ -z "$plan_info_json" || "$plan_info_json" == "null" ]]; then
  echo "ERROR: Could not retrieve info for App Service Plan '${plan_name}'."
  exit 1
fi

current_sku="$(echo "$plan_info_json" | jq -r '.sku.name')"
echo "Current SKU: $current_sku"

##############################################################################
# 3) Determine the next-lower SKU from our map
##############################################################################
echo "Using SKU down-map:"
echo "$SKU_DOWN_MAP_JSON" | jq '.'

# Look up next-lower SKU from the JSON map
next_sku="$(echo "$SKU_DOWN_MAP_JSON" | jq -r --arg c "$current_sku" '.[$c] // empty')"

if [[ -z "$next_sku" ]]; then
  echo "ERROR: No 'down-sku' found for '$current_sku' in the provided SKU down-map."
  echo "Please update your SKU_DOWN_MAP_JSON to handle this case."
  exit 1
fi

echo "Proposed new (lower) SKU: $next_sku"

##############################################################################
# 4) Perform the scale-down using az appservice plan update
##############################################################################
echo "Scaling App Service Plan '${plan_name}' from SKU '${current_sku}' -> '${next_sku}'..."
update_output="$(az appservice plan update \
  --name "$plan_name" \
  --resource-group "${AZ_RESOURCE_GROUP}" \
  --sku "$next_sku" \
  2>&1 || true)"

# Detect errors:
if echo "$update_output" | grep -qi "error"; then
  echo "ERROR encountered during scale-down:"
  echo "$update_output"
  exit 1
fi

echo "Scale-down command output:"
echo "$update_output"

# Confirm new SKU by re-checking the plan
recheck_json="$(az appservice plan show \
  --name "$plan_name" \
  --resource-group "${AZ_RESOURCE_GROUP}" \
  --output json 2>/dev/null || true)"
confirmed_sku="$(echo "$recheck_json" | jq -r '.sku.name')"

if [[ "$confirmed_sku" == "$next_sku" ]]; then
  echo "SUCCESS: Plan '${plan_name}' is now on SKU '${confirmed_sku}'."
else
  echo "WARNING: The plan still reports SKU '${confirmed_sku}' instead of '${next_sku}'."
  echo "Check Azure Portal or CLI logs to confirm the update took effect."
fi

echo "Done."
