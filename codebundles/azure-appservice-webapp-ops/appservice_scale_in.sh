#!/usr/bin/env bash
#
# scale_in_factor_unified.sh
#
# Scales in (reduces instances) for an Azure App Service by a factor,
# automatically handling both:
#   - Arc-enabled App Services on Kubernetes
#   - Regular Azure App Services
#
# ENV VARS:
#   AZ_RESOURCE_GROUP   - The resource group name
#   APP_SERVICE_NAME    - The web app name
#   SCALE_IN_FACTOR     - An integer factor, e.g. 2 means "halve" the current count.
#
# Usage:
#   export AZ_RESOURCE_GROUP="myRG"
#   export APP_SERVICE_NAME="myWebApp"
#   export SCALE_IN_FACTOR="2"
#   bash scale_in_factor_unified.sh
#
# Note: If dividing results in <1, we default to 1 worker to avoid fully disabling the app.

# Function to extract timestamp from log line, fallback to current time
extract_log_timestamp() {
    local log_line="$1"
    local fallback_timestamp=$(date -u +"%Y-%m-%dT%H:%M:%S.%3NZ")
    
    if [[ -z "$log_line" ]]; then
        echo "$fallback_timestamp"
        return
    fi
    
    # Try to extract common timestamp patterns
    # ISO 8601 format: 2024-01-15T10:30:45.123Z
    if [[ "$log_line" =~ ([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]{3})?Z?) ]]; then
        echo "${BASH_REMATCH[1]}"
        return
    fi
    
    # Standard log format: 2024-01-15 10:30:45
    if [[ "$log_line" =~ ([0-9]{4}-[0-9]{2}-[0-9]{2}[[:space:]]+[0-9]{2}:[0-9]{2}:[0-9]{2}) ]]; then
        # Convert to ISO format
        local extracted_time="${BASH_REMATCH[1]}"
        local iso_time=$(date -d "$extracted_time" -u +"%Y-%m-%dT%H:%M:%S.000Z" 2>/dev/null)
        if [[ $? -eq 0 ]]; then
            echo "$iso_time"
        else
            echo "$fallback_timestamp"
        fi
        return
    fi
    
    # DD-MM-YYYY HH:MM:SS format
    if [[ "$log_line" =~ ([0-9]{2}-[0-9]{2}-[0-9]{4}[[:space:]]+[0-9]{2}:[0-9]{2}:[0-9]{2}) ]]; then
        local extracted_time="${BASH_REMATCH[1]}"
        # Convert DD-MM-YYYY to YYYY-MM-DD for date parsing
        local day=$(echo "$extracted_time" | cut -d' ' -f1 | cut -d'-' -f1)
        local month=$(echo "$extracted_time" | cut -d' ' -f1 | cut -d'-' -f2)
        local year=$(echo "$extracted_time" | cut -d' ' -f1 | cut -d'-' -f3)
        local time_part=$(echo "$extracted_time" | cut -d' ' -f2)
        local iso_time=$(date -d "$year-$month-$day $time_part" -u +"%Y-%m-%dT%H:%M:%S.000Z" 2>/dev/null)
        if [[ $? -eq 0 ]]; then
            echo "$iso_time"
        else
            echo "$fallback_timestamp"
        fi
        return
    fi
    
    # Fallback to current timestamp
    echo "$fallback_timestamp"
}

set -euo pipefail

##############################################################################
# 1) Validate environment
##############################################################################
: "${AZ_RESOURCE_GROUP:?Must set AZ_RESOURCE_GROUP}"
: "${APP_SERVICE_NAME:?Must set APP_SERVICE_NAME}"
: "${SCALE_IN_FACTOR:?Must set SCALE_IN_FACTOR (e.g., 2, 3, etc.)}"

if ! [[ "$SCALE_IN_FACTOR" =~ ^[0-9]+$ ]]; then
  echo "ERROR: SCALE_IN_FACTOR must be an integer (e.g. 2, 3). Got: '$SCALE_IN_FACTOR'"
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
# or includes "kube" for Arc-enabled apps.
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
is_arc=false
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
  echo "Will rely on arc-based scale; no direct .sku.capacity for Arc. Defaulting to 1 if uncertain."
fi

echo "Current worker count: $current_workers"
echo "Scale-in factor:      $SCALE_IN_FACTOR"

##############################################################################
# 4) Calculate new worker count
##############################################################################
# For scale-in by factor, new = current // factor
# e.g. if current=4, factor=2 => new=2
# If new < 1 => set new=1 to avoid fully disabling. Adjust if you want 0.
new_count=$(( current_workers / SCALE_IN_FACTOR ))
if [[ "$new_count" -lt 1 ]]; then
  new_count=1
fi

echo "New worker count will be: $new_count"

##############################################################################
# 5) Perform the scale-in
##############################################################################
if [ "$is_arc" = true ]; then
  # Arc scenario => az webapp scale --instance-count
  echo "Scaling in (Arc) '${APP_SERVICE_NAME}' to ${new_count} workers..."
  scale_cmd_output="$(az webapp scale \
    --name "${APP_SERVICE_NAME}" \
    --resource-group "${AZ_RESOURCE_GROUP}" \
    --instance-count "${new_count}" \
    2>&1 || true)"

  if echo "$scale_cmd_output" | grep -qi "error"; then
    echo "ERROR encountered during arc-based scale-in:"
    echo "$scale_cmd_output"
    exit 1
  fi

  echo "Scale-in command output (Arc):"
  echo "$scale_cmd_output"

  # Optionally, do a second "az webapp show" to verify. 
  # Arc doesn't store a typical plan .sku, so we'd need to parse logs or rely on the output.

else
  # Normal scenario => az appservice plan update --number-of-workers
  echo "Scaling in (Normal) plan '${plan_name}' to ${new_count} workers..."
  update_output="$(az appservice plan update \
    --name "${plan_name}" \
    --resource-group "${AZ_RESOURCE_GROUP}" \
    --number-of-workers "${new_count}" \
    2>&1 || true)"

  if echo "$update_output" | grep -qi "error"; then
    echo "ERROR encountered during scale-in (normal):"
    echo "$update_output"
    exit 1
  fi

  echo "Scale-in command output (Normal):"
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
