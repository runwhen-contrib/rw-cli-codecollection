#!/usr/bin/env bash
#
# Collect APIM Resource Information & Potential Issues
# For APIM ${APIM_NAME} in Resource Group ${AZ_RESOURCE_GROUP}
#
# Usage:
#   export AZ_RESOURCE_GROUP="myResourceGroup"
#   export APIM_NAME="myApimInstance"
#   # Optionally: export AZURE_RESOURCE_SUBSCRIPTION_ID="your-subscription-id"
#   ./gather_apim_resource_information.sh
#
# Description:
#   - Ensures correct subscription context
#   - Validates Resource Group
#   - Retrieves APIM details (location, SKU, hostnames, TLS versions, etc.)
#   - Logs issues in apim_config_issues.json, each containing {title, details, next_steps, severity}
#   - severity is numeric: 1=critical, 2=major, 3=minor, 4=informational
#   - Exports environment variables for subsequent scripts

set -euo pipefail

###############################################################################
# Get or set subscription ID
if [ -z "${AZURE_RESOURCE_SUBSCRIPTION_ID:-}" ]; then
    subscription=$(az account show --query "id" -o tsv)
    echo "AZURE_RESOURCE_SUBSCRIPTION_ID is not set. Using current subscription ID: $subscription"
else
    subscription="$AZURE_RESOURCE_SUBSCRIPTION_ID"
    echo "Using specified subscription ID: $subscription"
fi
az account set --subscription "$subscription"
###############################################################################

# Ensure required environment variables
: "${AZ_RESOURCE_GROUP:?Must set AZ_RESOURCE_GROUP}"
: "${APIM_NAME:?Must set APIM_NAME}"

echo "[INFO] Gathering APIM Resource Information..."
echo "       Resource Group: ${AZ_RESOURCE_GROUP}"
echo "       APIM Name:      ${APIM_NAME}"

# Verify the Resource Group exists
echo "[INFO] Checking Resource Group..."
az group show --name "${AZ_RESOURCE_GROUP}" --output none

# Retrieve APIM details
echo "[INFO] Retrieving APIM instance details..."
APIM_JSON="$(az apim show \
  --name "${APIM_NAME}" \
  --resource-group "${AZ_RESOURCE_GROUP}" \
  --output json)"

APIM_ID="$(echo "${APIM_JSON}" | jq -r '.id')"
APIM_LOCATION="$(echo "${APIM_JSON}" | jq -r '.location')"
APIM_SKU="$(echo "${APIM_JSON}" | jq -r '.sku.name')"

# Hostname configurations
APIM_HOSTNAME_CONFIGS="$(echo "${APIM_JSON}" | jq -r '.hostnameConfigurations')"

# Network / Public IP
APIM_VNET_TYPE="$(echo "${APIM_JSON}" | jq -r '.vpnConfiguration.vnetType? // empty')"
APIM_PUBLIC_IP_ID="$(echo "${APIM_JSON}" | jq -r '.publicIpAddressId? // empty')"

# Relevant URLs
GATEWAY_URL="$(echo "${APIM_JSON}" | jq -r '.gatewayUrl? // empty')"
GATEWAY_REGIONAL_URL="$(echo "${APIM_JSON}" | jq -r '.gatewayRegionalUrl? // empty')"
PORTAL_URL="$(echo "${APIM_JSON}" | jq -r '.portalUrl? // empty')"
SCM_URL="$(echo "${APIM_JSON}" | jq -r '.scmUrl? // empty')"
DEV_PORTAL_URL="$(echo "${APIM_JSON}" | jq -r '.customProperties.developerPortalUrl? // empty')"
MGMT_API_URL="$(echo "${APIM_JSON}" | jq -r '.customProperties.managementApiUrl? // empty')"

echo ""
echo "[INFO] APIM '${APIM_NAME}' basic info:"
echo "       ID:         ${APIM_ID}"
echo "       Location:   ${APIM_LOCATION}"
echo "       SKU:        ${APIM_SKU}"
echo "       VNET:       ${APIM_VNET_TYPE:-none}"
echo "       Public IP:  ${APIM_PUBLIC_IP_ID:-none}"

echo "[INFO] APIM URLs (if configured):"
[ -n "${GATEWAY_URL}" ] &&          echo "   Gateway URL:          ${GATEWAY_URL}"
[ -n "${GATEWAY_REGIONAL_URL}" ] && echo "   Gateway Regional URL: ${GATEWAY_REGIONAL_URL}"
[ -n "${PORTAL_URL}" ] &&           echo "   Portal URL:           ${PORTAL_URL}"
[ -n "${SCM_URL}" ] &&              echo "   SCM URL:              ${SCM_URL}"
[ -n "${DEV_PORTAL_URL}" ] &&       echo "   Dev Portal URL:       ${DEV_PORTAL_URL}"
[ -n "${MGMT_API_URL}" ] &&         echo "   Management API URL:   ${MGMT_API_URL}"

###############################################################################
# Track potential issues
declare -a ISSUES=()

# Helper: Add an issue
# severity is numeric => 1=critical, 2=major, 3=minor, 4=informational
add_issue() {
  local title="$1"
  local details="$2"
  local next_steps="$3"
  local severity="$4"  # Must be 1,2,3,4
  ISSUES+=("{\"title\":\"${title}\",\"details\":\"${details}\",\"next_steps\":\"${next_steps}\",\"severity\":${severity}}")
}

###############################################################################
# Check TLS Versions, Certificates, etc.
echo ""
echo "[INFO] Checking hostname configurations..."
echo "${APIM_HOSTNAME_CONFIGS}" | jq -cr '.[]?' | while read -r config; do
  hostName="$(echo "$config" | jq -r '.hostName')"
  hostType="$(echo "$config" | jq -r '.hostNameType')"
  tlsVersion="$(echo "$config" | jq -r '.minTlsVersion? // "N/A"')"
  certSubject="$(echo "$config" | jq -r '.certificate?.subject? // "No Certificate Found"')"

  echo " - HostName: ${hostName}"
  echo "   Type:     ${hostType}"
  echo "   TLS Min:  ${tlsVersion}"
  echo "   Cert:     ${certSubject}"

  # Example check: TLS < 1.2 => severity=4 (informational)
  if [ "${tlsVersion}" != "N/A" ] && [ "${tlsVersion}" != "1.2" ] && [ "${tlsVersion}" != "1.3" ]; then
    t="TLS version below 1.2"
    d="Host '${hostName}' is using TLS < 1.2 (current: ${tlsVersion})."
    n="Review runbook task for adjusting TLS settings. A minimum of 1.2 is recommended for APIM '${APIM_NAME}' in RG '${AZ_RESOURCE_GROUP}'."
    s=4
    echo "[WARNING] ${d}"
    add_issue "${t}" "${d}" "${n}" "${s}"
  fi

  # Example check: Missing cert for Proxy => severity=4 (informational)
  if [ "${certSubject}" == "No Certificate Found" ] && [ "${hostType}" == "Proxy" ]; then
    t="Proxy host missing certificate"
    d="Host '${hostName}' is configured as Proxy but no certificate is attached."
    n="Review runbook task for custom domain certificate assignment. APIM '${APIM_NAME}' in RG '${AZ_RESOURCE_GROUP}'."
    s=4
    echo "[WARNING] ${d}"
    add_issue "${t}" "${d}" "${n}" "${s}"
  fi
done

###############################################################################
# Example: No VNET integration => severity=4 (informational)
if [ -z "${APIM_VNET_TYPE}" ]; then
  echo "[INFO] APIM is NOT using a VNET (publicly accessible)."
  t="No VNET integration for APIM \`${APIM_NAME}\`"
  d="APIM ${APIM_NAME} in is publicly accessible; no VNET integration is configured."
  n="Enable VNET integration on APIM \`${APIM_NAME}\` in Resource Group \`${AZ_RESOURCE_GROUP}\`."
  s=4
  add_issue "${t}" "${d}" "${n}" "${s}"
fi

# Example: Public IP assigned => severity=4 (informational)
if [ -n "${APIM_PUBLIC_IP_ID}" ]; then
  echo "[WARNING] APIM has a Public IP (${APIM_PUBLIC_IP_ID}). Ensure external access is intended."

  t="APIM \`${APIM_NAME}\` is assigned a Public IP"
  d="APIM ${APIM_NAME} has a public IP bound, making it externally reachable."
  n="Remove or disable the Public IP if private access is required. APIM \`${APIM_NAME}\` in Resource Group \`${AZ_RESOURCE_GROUP}\`."
  s=4
  add_issue "${t}" "${d}" "${n}" "${s}"
fi

###############################################################################
# Write issues to apim_config_issues.json as { "issues": [ {...}, ... ] }
if [ "${#ISSUES[@]}" -gt 0 ]; then
  local_issues="[ $(IFS=,; echo "${ISSUES[*]}") ]"
else
  local_issues="[]"
fi

final_json="{\"issues\": ${local_issues}}"
echo "${final_json}" > apim_config_issues.json

echo ""
echo "[INFO] Potential issues captured in apim_config_issues.json:"
cat apim_config_issues.json
echo ""

###############################################################################
# Export environment variables for subsequent scripts
export AZURE_RESOURCE_SUBSCRIPTION_ID="$subscription"
export SUBSCRIPTION_ID="$subscription"
export APIM_LOCATION
export APIM_SKU
export GATEWAY_URL
export DEV_PORTAL_URL
export MGMT_API_URL

echo "[INFO] Done gathering APIM resource information."
