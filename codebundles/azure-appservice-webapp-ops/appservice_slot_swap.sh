#!/usr/bin/env bash
#
# swap_slots_appservice.sh
#
# This script checks if an Azure App Service supports slots, finds the available slots,
# and performs a swap between SOURCE_SLOT and TARGET_SLOT. If SOURCE_SLOT and/or
# TARGET_SLOT are not explicitly set, the script attempts to determine them automatically:
#   - "production" (default slot) is where isSlot=false
#   - if exactly one other slot is found, that's used as SOURCE_SLOT
#
# ENVIRONMENT VARIABLES:
#   AZ_RESOURCE_GROUP - Resource group name (required)
#   APP_SERVICE_NAME  - App Service name (required)
#   SOURCE_SLOT       - (optional) If not provided, we attempt to deduce
#   TARGET_SLOT       - (optional) If not provided, we attempt to deduce
#
# Usage:
#   export AZ_RESOURCE_GROUP="myRG"
#   export APP_SERVICE_NAME="myAppService"
#   # optionally: export SOURCE_SLOT="staging"
#   # optionally: export TARGET_SLOT="production"
#   bash swap_slots_appservice.sh
#

set -euo pipefail

##############################################################################
# 1) Check required environment
##############################################################################
: "${AZ_RESOURCE_GROUP:?Must set AZ_RESOURCE_GROUP}"
: "${APP_SERVICE_NAME:?Must set APP_SERVICE_NAME}"

SOURCE_SLOT="${SOURCE_SLOT:-}"  # might be empty
TARGET_SLOT="${TARGET_SLOT:-}"  # might be empty

##############################################################################
# 2) Check Plan SKU
##############################################################################
echo "Retrieving App Service '${APP_SERVICE_NAME}' in resource group '${AZ_RESOURCE_GROUP}'..."
app_info="$(az webapp show \
  --resource-group "${AZ_RESOURCE_GROUP}" \
  --name "${APP_SERVICE_NAME}" \
  --output json 2>/dev/null || true)"

if [[ -z "${app_info}" || "${app_info}" == "null" ]]; then
  echo "ERROR: Could not retrieve info for App Service '${APP_SERVICE_NAME}'."
  exit 1
fi

plan_id="$(echo "${app_info}" | jq -r '.serverFarmId // .appServicePlanId // empty')"
if [[ -z "${plan_id}" ]]; then
  echo "ERROR: Neither 'serverFarmId' nor 'appServicePlanId' found in webapp JSON!"
  exit 1
fi

plan_name="$(basename "${plan_id}")"

echo "Fetching plan info for '${plan_name}'..."
plan_info="$(az appservice plan show \
  --name "${plan_name}" \
  --resource-group "${AZ_RESOURCE_GROUP}" \
  --output json 2>/dev/null || true)"

if [[ -z "${plan_info}" || "${plan_info}" == "null" ]]; then
  echo "ERROR: Could not retrieve info for App Service Plan '${plan_name}'."
  exit 1
fi

sku_name="$(echo "${plan_info}" | jq -r '.sku.name // empty')"
if [[ -z "${sku_name}" ]]; then
  echo "ERROR: No SKU name found in plan info!"
  exit 1
fi

sku_name_upper="$(echo "${sku_name}" | tr '[:lower:]' '[:upper:]')"
# Quick check: must be Standard or Premium tier to support multiple slots
if ! echo "${sku_name_upper}" | grep -Eq '^(S|P|P1V|WS)$'; then
  echo "ERROR: Current SKU '${sku_name}' does not typically support multiple slots."
  echo "Upgrade to at least Standard (S1) to have multiple deployment slots."
  exit 1
fi

##############################################################################
# 3) List all slots
##############################################################################
echo "Listing slots for '${APP_SERVICE_NAME}'..."
slots_json="$(az webapp deployment slot list \
  --name "${APP_SERVICE_NAME}" \
  --resource-group "${AZ_RESOURCE_GROUP}" \
  --output json 2>/dev/null || true)"

# The array includes the default slot (production) as well, with "isSlot": false?
# Actually, 'slot list' doesn't usually show the production slot. 
# We'll handle that by explicitly including it below.
if [[ -z "${slots_json}" || "${slots_json}" == "null" ]]; then
  echo "No non-production slots found. That means there's only the default 'production' slot."
  # If user asked for a swap, it won't be possible unless they have at least 2 slots.
  echo "Exiting..."
  exit 1
fi

# parse the array
# Each item typically has fields like:
#  {
#    "name": "myApp/staging",
#    "slot": "staging",
#    "isSlot": true,
#    "state": "Running"
#  }
# 'production' is not included in this list if we use `az webapp deployment slot list`.
# We'll define a pseudo-entry for production.

slot_list="$(echo "$slots_json" | jq -c '.[]')"
production_entry="{\"name\":\"${APP_SERVICE_NAME}\",\"slot\":\"production\",\"isSlot\":false}"

##############################################################################
# Merge the "production" slot with the others so we have a consistent list
##############################################################################
# We'll produce an array of slot objects, each with "slot" and "isSlot".
merged_slots="$(jq -cs '.[0] + .[1]' \
  <(echo "[$production_entry]") \
  <(echo "[${slot_list}]"))"

# merged_slots is an array of e.g.:
# [
#   {"name":"myApp","slot":"production","isSlot":false},
#   {"name":"myApp/staging","slot":"staging","isSlot":true}
# ]

# function to see if a slot exists in merged list
function slot_exists() {
  local slot_name="$1"
  echo "$merged_slots" | jq -e --arg s "$slot_name" '.[] | select(.slot==$s)' >/dev/null 2>&1
}

# We'll also gather them into arrays for potential auto-detection
production_slot="$(echo "$merged_slots" | jq '.[] | select(.isSlot==false) | .slot' -r)"
nonprod_slots="$(echo "$merged_slots" | jq '.[] | select(.isSlot==true)  | .slot' -r | xargs echo || true)"

echo "Available Slots (including production):"
echo "$merged_slots" | jq -r '.[] | " - \(.slot) (isSlot=\(.isSlot))"'
echo ""

##############################################################################
# 4) Auto-determine source/target if needed
##############################################################################
if [[ -z "${SOURCE_SLOT}" || -z "${TARGET_SLOT}" ]]; then
  echo "SOURCE_SLOT or TARGET_SLOT not set. Attempting to auto-discover..."

  # if we only have 1 non-production slot, we might guess:
  #   SOURCE_SLOT = that single non-prod slot
  #   TARGET_SLOT = production
  # This is a naive assumption. If you have multiple, we can't guess.

  # how many nonproduction slots do we have?
  count_nonprod="$(echo "$nonprod_slots" | wc -w | xargs)"  # number of slot tokens

  if [[ "$count_nonprod" -eq 0 ]]; then
    echo "ERROR: No non-production slot found; cannot do a swap."
    exit 1
  elif [[ "$count_nonprod" -eq 1 ]]; then
    # we have exactly one non-prod slot
    single_slot="$(echo "$nonprod_slots" | xargs)"
    if [[ -z "${SOURCE_SLOT}" ]]; then
      SOURCE_SLOT="$single_slot"
    fi
    if [[ -z "${TARGET_SLOT}" ]]; then
      TARGET_SLOT="production"
    fi
    echo "Auto-detected: SOURCE_SLOT='${SOURCE_SLOT}', TARGET_SLOT='${TARGET_SLOT}'"
  else
    echo "ERROR: Multiple non-production slots exist: $nonprod_slots"
    echo "You must explicitly set SOURCE_SLOT and TARGET_SLOT."
    exit 1
  fi
fi

##############################################################################
# 5) Verify the requested slots actually exist
##############################################################################
# By now, SOURCE_SLOT and TARGET_SLOT should be set. Let's confirm they're in merged_slots.
if ! slot_exists "${SOURCE_SLOT}"; then
  echo "ERROR: Source slot '${SOURCE_SLOT}' not found among slots."
  exit 1
fi

if ! slot_exists "${TARGET_SLOT}"; then
  echo "ERROR: Target slot '${TARGET_SLOT}' not found among slots."
  exit 1
fi

echo "Final: Source='${SOURCE_SLOT}', Target='${TARGET_SLOT}'"

# If source == target, no swap needed
if [[ "${SOURCE_SLOT}" == "${TARGET_SLOT}" ]]; then
  echo "ERROR: SOURCE_SLOT and TARGET_SLOT are the same. No swap to do."
  exit 1
fi

##############################################################################
# 6) Perform the Slot Swap
##############################################################################
echo "Swapping slots: '${SOURCE_SLOT}' -> '${TARGET_SLOT}' for app '${APP_SERVICE_NAME}'..."

swap_output="$(az webapp deployment slot swap \
  --name "${APP_SERVICE_NAME}" \
  --resource-group "${AZ_RESOURCE_GROUP}" \
  --slot "${SOURCE_SLOT}" \
  --target-slot "${TARGET_SLOT}" \
  2>&1 || true)"

if echo "${swap_output}" | grep -qi "error"; then
  echo "ERROR: Slot swap encountered issues:"
  echo "${swap_output}"
  exit 1
fi

echo "Slot Swap Output:"
echo "${swap_output}"

##############################################################################
# 7) (Optional) Verify
##############################################################################
verify_json="$(az webapp show \
  --name "${APP_SERVICE_NAME}" \
  --resource-group "${AZ_RESOURCE_GROUP}" \
  --slot "${TARGET_SLOT}" \
  --output json 2>/dev/null || true)"

if [[ -n "${verify_json}" && "${verify_json}" != "null" ]]; then
  new_state="$(echo "${verify_json}" | jq -r '.state // empty')"
  echo "Verification: target slot '${TARGET_SLOT}' is now in state: '${new_state}'"
else
  echo "WARNING: Could not retrieve info for target slot '${TARGET_SLOT}' post-swap."
fi

echo "Slot swap complete."
