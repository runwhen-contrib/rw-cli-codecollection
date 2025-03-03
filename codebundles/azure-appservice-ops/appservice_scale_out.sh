#!/usr/bin/env bash
#
# scale_out_factor_unified.sh
#
# Scales out (increases instances) for an Azure App Service by a factor, 
# automatically handling:
#   - Arc-enabled App Services on Kubernetes (use "az webapp scale --instance-count")
#   - Regular Azure App Services (use "az appservice plan update --number-of-workers")
#
# ENV VARS NEEDED:
#   AZ_RESOURCE_GROUP   - The resource group name (e.g. "myRG")
#   APP_SERVICE_NAME    - The web app name (e.g. "myWebApp")
#   SCALE_OUT_FACTOR    - An integer factor. If current workers=2 and factor=2, new=4.
#
# Usage example:
#   export AZ_RESOURCE_GROUP="myRG"
#   export APP_SERVICE_NAME="myWebApp"
#   export SCALE_OUT_FACTOR="2"
#   bash scale_out_factor_unified.sh
#

set -euo pipefail

##############################################################################
# 1) Validate environment
##############################################################################
: "${AZ_RESOURCE_GROUP:?Must set AZ_RESOURCE_GROUP}"
: "${APP_SERVICE_NAME:?Must set APP_SERVICE_NAME}"
: "${SCALE_OUT_FACTOR:?Must set SCALE_OUT_FACTOR (e.g. 2, 3, etc.)}"

if ! [[ "$SCALE_OUT_FACTOR" =~ ^[0-9]+$ ]]; then
  echo "ERROR: SCALE_OUT_FACTOR must be an integer (e.g. 2, 3). Got: '$SCALE_OUT_FACTOR'"
  exit 1
fi

##############################################################################
# 2) Retrieve the web app JSON and Plan info
##############################################################################
echo "Retrieving App Service '${APP_SERVICE_NAME}' in resource group '${AZ_RESOURCE_GROUP}'..."
app_info_json="$(az webapp show \
  --resource-group "${AZ_RESOURCE_GROUP}" \
  --name "${APP_SERVICE_NAME}" \
  --output json 2>/dev/null || true)"

if [[ -z "$app_info_json" || "$app_info_json" == "null" ]]; then
  echo "ERROR: Could not retrieve info for App Service '${APP_SERVICE_NAME}'."
  exit 1
fi

# "kind" is often "app,linux,container" for normal Linux webapps,
# or includes "kube" / "kubeApp" for Arc-enabled apps.
kind="$(echo "$app_info_json" | jq -r '.kind // ""')"
echo "Detected kind: '${kind}'"

# Extract plan name (for normal scenario)
server_farm_id="$(echo "$app_info_json" | jq -r '.serverFarmId // .appServicePlanId // empty')"
if [[ -z "$server_farm_id" ]]; then
  echo "ERROR: Neither 'serverFarmId' nor 'appServicePlanId' found!"
  exit 1
fi

plan_name="$(basename "$server_farm_id")"

##############################################################################
# 3) Determine the current worker count
##############################################################################
# For normal (non-Arc), we'll parse the plan's ".sku.capacity".
# For Arc-based, we can parse "az webapp show" itself for a worker count, 
# but typically Arc-based scale is *only* via "az webapp scale" so we might skip.
#
# We'll do our best to unify how we get 'current_workers' as ".sku.capacity"
# for normal plan. If Arc, we can't always do that. We'll fallback to 1 if uncertain.
##############################################################################
is_arc=false

# A naive check: if "kube" (or "kubeApp") is in kind, we assume Arc scenario
if echo "$kind" | grep -qi "kube"; then
  is_arc=true
  echo "Arc-enabled Kubernetes-based App Service detected."
fi

current_workers=1  # fallback if we can't parse
if [ "$is_arc" = false ]; then
  # For normal: get plan info to find .sku.capacity
  plan_info="$(az appservice plan show \
    --name "${plan_name}" \
    --resource-group "${AZ_RESOURCE_GROUP}" \
    --output json 2>/dev/null || true)"

  if [[ -z "$plan_info" || "$plan_info" == "null" ]]; then
    echo "ERROR: Could not retrieve plan info for '${plan_name}'."
    exit 1
  fi
  
  current_workers="$(echo "$plan_info" | jq -r '.sku.capacity')"
  if ! [[ "$current_workers" =~ ^[0-9]+$ ]]; then
    echo "WARN: The current worker count '${current_workers}' is not numeric. Defaulting to 1."
    current_workers=1
  fi
else
  # Arc-based doesn't store capacity in an appservice plan. 
  # Optionally, we can attempt to parse the "properties" from az webapp show to see if there's a worker count, 
  # but the typical approach is to scale with "az webapp scale" directly.
  echo "Will rely on arc-based scale. We'll assume 'current_workers' is 1 if not known."
fi

echo "Current worker count: $current_workers"
echo "Scale-out factor:     $SCALE_OUT_FACTOR"

##############################################################################
# 4) Calculate new worker count
##############################################################################
if [[ "$current_workers" == "0" ]]; then
  new_count="$SCALE_OUT_FACTOR"
else
  new_count=$(( current_workers * SCALE_OUT_FACTOR ))
fi

echo "New worker count will be: $new_count"

##############################################################################
# 5) Perform the scale-out
##############################################################################
if [ "$is_arc" = true ]; then
  # Arc scenario => az webapp scale
  echo "Scaling (Arc-enabled) '${APP_SERVICE_NAME}' to ${new_count} via 'az webapp scale'..."
  scale_cmd_output="$(az webapp scale \
    --name "${APP_SERVICE_NAME}" \
    --resource-group "${AZ_RESOURCE_GROUP}" \
    --instance-count "${new_count}" \
    2>&1 || true)"

  if echo "$scale_cmd_output" | grep -qi "error"; then
    echo "ERROR encountered during arc-based scale-out:"
    echo "$scale_cmd_output"
    exit 1
  fi

  echo "Scale-out command output (Arc):"
  echo "$scale_cmd_output"

  # Verification for Arc might be limited if we can't query .sku. 
  # Possibly re-run "az webapp show" or rely on cluster logs
  # We'll skip a direct numeric check here

else
  # Normal scenario => az appservice plan update
  echo "Scaling (Normal) plan '${plan_name}' to ${new_count} workers via 'az appservice plan update'..."
  update_output="$(az appservice plan update \
    --name "${plan_name}" \
    --resource-group "${AZ_RESOURCE_GROUP}" \
    --number-of-workers "${new_count}" \
    2>&1 || true)"

  if echo "$update_output" | grep -qi "error"; then
    echo "ERROR encountered during scale-out (normal):"
    echo "$update_output"
    exit 1
  fi

  echo "Scale-out command output (Normal):"
  echo "$update_output"

  # Re-check plan
  plan_info_after="$(az appservice plan show \
    --name "${plan_name}" \
    --resource-group "${AZ_RESOURCE_GROUP}" \
    --output json 2>/dev/null || true)"

  confirmed_workers="$(echo "$plan_info_after" | jq -r '.sku.capacity')"
  if [[ "$confirmed_workers" == "$new_count" ]]; then
    echo "SUCCESS: Worker count is now ${confirmed_workers}."
  else
    echo "WARNING: The plan shows ${confirmed_workers} workers instead of ${new_count}."
    echo "Check Azure Portal or CLI logs to confirm the update took effect."
  fi
fi

echo "Done."
