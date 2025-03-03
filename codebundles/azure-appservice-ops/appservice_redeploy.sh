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

    if echo "$container_restart" | grep -qi "error"; then
      echo "ERROR: Container restart encountered an error:" 1>&2
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

    if echo "$redeploy_out" | grep -qi "error"; then
      echo "ERROR: config-zip encountered an error:" 1>&2
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
