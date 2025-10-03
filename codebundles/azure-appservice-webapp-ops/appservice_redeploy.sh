#!/usr/bin/env bash
#
# unified_redeploy.sh
#
# This script auto-detects how an Azure App Service is deployed (container vs code)
# by inspecting "linuxFxVersion" and "kind" properties, then performs an appropriate redeployment.
#
# Scenarios:
#  1) Container-based (Linux custom container, e.g. "DOCKER|..."): run a container update approach, or restart
#  2) Code-based (e.g. Windows .NET or Linux code) -> run "az webapp deployment source config-zip"
#  3) Otherwise, ask the user to specify a fallback approach, or error out
#
# ENVIRONMENT VARIABLES:
#   AZ_RESOURCE_GROUP   - Resource group name
#   APP_SERVICE_NAME    - Web app name
#   ZIP_PACKAGE_PATH    - For code-based deploy, the path to the ZIP package
#   FORCE_DEPLOY_TYPE   - (Optional) "container" or "code" to override detection
#
# Usage:
#   export AZ_RESOURCE_GROUP="myRG"
#   export APP_SERVICE_NAME="myApp"
#   export ZIP_PACKAGE_PATH="./myApp.zip"
#   bash unified_redeploy.sh
#
#   # or to force a container approach:
#   export FORCE_DEPLOY_TYPE="container"
#   bash unified_redeploy.sh
#

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

ZIP_PACKAGE_PATH="${ZIP_PACKAGE_PATH:-}"
FORCE_DEPLOY_TYPE="${FORCE_DEPLOY_TYPE:-}"

##############################################################################
# 2) Retrieve app info and detect deployment type
##############################################################################
echo "Retrieving App Service '${APP_SERVICE_NAME}' from resource group '${AZ_RESOURCE_GROUP}'..."
app_info_json="$(az webapp show \
  --name "${APP_SERVICE_NAME}" \
  --resource-group "${AZ_RESOURCE_GROUP}" \
  --output json 2>/dev/null || true)"

if [[ -z "$app_info_json" || "$app_info_json" == "null" ]]; then
  echo "ERROR: Could not retrieve info for '${APP_SERVICE_NAME}'. Check that it exists and the RG is correct." 1>&2
  exit 1
fi

kind="$(echo "$app_info_json" | jq -r '.kind // ""')"
linux_fx_version="$(echo "$app_info_json" | jq -r '.siteConfig.linuxFxVersion // ""')"
echo "Detected kind='${kind}' and linuxFxVersion='${linux_fx_version}'"

deploy_type="unknown"

if [[ -n "$FORCE_DEPLOY_TYPE" ]]; then
  # Force override if the user wants a specific approach
  deploy_type="$FORCE_DEPLOY_TYPE"
  echo "FORCE_DEPLOY_TYPE set -> using '${deploy_type}'"
else
  # Auto-detect
  # 1) If linuxFxVersion starts with "DOCKER|" => container
  # 2) Else likely code-based -> "config-zip"
  # (You could refine checks: e.g. if "kind" includes "linux,container" or if "linuxFxVersion" is "DOTNETCORE|3.1" => code-based)
  if echo "$linux_fx_version" | grep -qi '^DOCKER|'; then
    deploy_type="container"
  else
    # e.g. "DOTNETCORE|3.1", "PYTHON|3.9", or Windows .NET => treat as code-based
    deploy_type="code"
  fi
fi

echo "Determined deploy_type='${deploy_type}'"

##############################################################################
# 3) Perform the Redeployment
##############################################################################
case "$deploy_type" in
  container)
    echo "=== Container-based Redeploy ==="
    # For many custom container scenarios, there's not a single "redeploy" command from CLI.
    # Usually you'd do something like: re-set the container image, or trigger a restart.
    # For example, if you changed the image tag, you'd do:
    #
    # az webapp config container set \
    #   --name "${APP_SERVICE_NAME}" \
    #   --resource-group "${AZ_RESOURCE_GROUP}" \
    #   --docker-custom-image-name "mycontainer:latest" \
    #   --docker-registry-server-url "..."
    #
    # or just do a simple "restart" to force the container to pull again if "DOCKER|myImage:latest" is used:
    echo "Forcing container restart to pull the latest image..."
    container_restart="$(az webapp restart \
      --name "${APP_SERVICE_NAME}" \
      --resource-group "${AZ_RESOURCE_GROUP}" 2>&1 || true)"

    if grep -i error; then
      # Extract timestamp from the error line
      error_line=$(grep -i error | head -1)
      log_timestamp=$(extract_log_timestamp "$error_line")
      echo "Error: Container restart encountered an error: (detected at $log_timestamp)" 1>&2
      echo "$container_restart" 1>&2
      exit 1
    fi

    echo "Container redeploy (restart) complete."
    ;;

  code)
    echo "=== Code-based Redeploy (config-zip) ==="
    if [[ -z "$ZIP_PACKAGE_PATH" ]]; then
      echo "ERROR: For code-based redeploy, you must set ZIP_PACKAGE_PATH." 1>&2
      exit 1
    fi

    # Run the config-zip approach
    redeploy_out="$(az webapp deployment source config-zip \
      --resource-group "${AZ_RESOURCE_GROUP}" \
      --name "${APP_SERVICE_NAME}" \
      --src "${ZIP_PACKAGE_PATH}" \
      2>&1 || true)"

    if grep -i error; then
      # Extract timestamp from the error line
      error_line=$(grep -i error | head -1)
      log_timestamp=$(extract_log_timestamp "$error_line")
      echo "Error: config-zip encountered an error: (detected at $log_timestamp)" 1>&2
      echo "$redeploy_out" 1>&2
      exit 1
    fi
    echo "Code-based redeploy via config-zip complete."
    ;;

  *)
    echo "ERROR: Could not determine a valid deployment approach. (Got '${deploy_type}')" 1>&2
    echo "Set FORCE_DEPLOY_TYPE='container' or 'code' or refine the detection logic." 1>&2
    exit 1
    ;;
esac

echo "Done."
