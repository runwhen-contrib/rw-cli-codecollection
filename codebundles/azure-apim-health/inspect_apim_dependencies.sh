#!/usr/bin/env bash
#
# Inspect Dependencies and Related Resources for APIM
# For APIM ${APIM_NAME} in Resource Group ${AZ_RESOURCE_GROUP}
#
# Usage:
#   export AZ_RESOURCE_GROUP="myResourceGroup"
#   export APIM_NAME="myApimInstance"
#   # Optionally: export AZURE_RESOURCE_SUBSCRIPTION_ID="sub-id"
#   # Optionally: export SKIP_CONNECTIVITY_CHECK="1" (if you want to skip the curl check)
#   ./inspect_apim_dependencies.sh
#
# Description:
#   1) Retrieves the APIM resource details.
#   2) Checks for Key Vault references in hostnameConfigurations (common for custom domain certs).
#   3) Lists all APIs, parses their serviceUrl => recognized as a "BackendService".
#   4) Optionally does a DNS & short curl check to confirm availability.
#   5) Logs issues if dependencies are missing or unreachable.
#   6) Writes final JSON => { "dependencies": [...], "issues": [...] }

set -euo pipefail

###############################################################################
# 1) Subscription context
###############################################################################
if [ -z "${AZURE_RESOURCE_SUBSCRIPTION_ID:-}" ]; then
  subscription=$(az account show --query "id" -o tsv)
  echo "[INFO] AZURE_RESOURCE_SUBSCRIPTION_ID is not set. Using current subscription ID: $subscription"
else
  subscription="$AZURE_RESOURCE_SUBSCRIPTION_ID"
  echo "[INFO] Using specified subscription ID: $subscription"
fi

echo "[INFO] Switching to subscription: $subscription"
az account set --subscription "$subscription"

: "${AZ_RESOURCE_GROUP:?Must set AZ_RESOURCE_GROUP}"
: "${APIM_NAME:?Must set APIM_NAME}"

OUTPUT_FILE="apim_dependencies.json"
dependencies_json='{"dependencies": [], "issues": []}'

echo "[INFO] Inspecting dependencies for APIM '$APIM_NAME' in RG '$AZ_RESOURCE_GROUP'..."

###############################################################################
# Helper: Add a dependency
###############################################################################
add_dependency() {
  local name="$1"
  local kind="$2"
  dependencies_json=$(echo "$dependencies_json" | jq \
    --arg n "$name" \
    --arg k "$kind" \
    '.dependencies += [{ "name": $n, "type": $k }]')
}

###############################################################################
# Helper: Add an issue
###############################################################################
add_issue() {
  local title="$1"
  local details="$2"
  local severity="$3"
  local next_steps="$4"

  dependencies_json=$(echo "$dependencies_json" | jq \
    --arg t "$title" \
    --arg d "$details" \
    --arg s "$severity" \
    --arg n "$next_steps" \
    '.issues += [{
      "title": $t,
      "details": $d,
      "next_steps": $n,
      "severity": ($s | tonumber)
    }]')
}

###############################################################################
# 2) Retrieve APIM resource (for hostnameConfigurations => Key Vault references)
###############################################################################
apim_show_err="apim_show_err.log"
if ! apim_json=$(az apim show \
      --resource-group "$AZ_RESOURCE_GROUP" \
      --name "$APIM_NAME" \
      -o json 2>"$apim_show_err"); then
  err_msg=$(cat "$apim_show_err")
  rm -f "$apim_show_err"
  echo "[ERROR] Could not retrieve APIM details."
  add_issue \
    "Failed to Retrieve APIM Resource" \
    "$err_msg" \
    "1" \
    "Check if APIM name/RG are correct and you have the right permissions."
  echo "$dependencies_json" > "$OUTPUT_FILE"
  exit 1
fi
rm -f "$apim_show_err"

hostname_configs=$(echo "$apim_json" | jq -c '.hostnameConfigurations // []')
while IFS= read -r hc; do
  # If using Key Vault for custom domain certs, typically 'keyVaultId' is present
  kv_ref=$(echo "$hc" | jq -r '.keyVaultId? // empty')
  if [[ -n "$kv_ref" && "$kv_ref" != "null" ]]; then
    echo "[INFO] Found Key Vault reference: $kv_ref"
    add_dependency "$kv_ref" "KeyVault"
  fi
done <<< "$hostname_configs"

###############################################################################
# 3) List all APIs => parse their serviceUrl => treat as "BackendService"
###############################################################################
apis_json_err="apis_json_err.log"
if ! apis_json=$(az apim api list \
      --resource-group "$AZ_RESOURCE_GROUP" \
      --service-name "$APIM_NAME" \
      -o json 2>"$apis_json_err"); then
  err_msg=$(cat "$apis_json_err")
  rm -f "$apis_json_err"
  echo "[ERROR] Failed to list APIs in APIM. Possibly name mismatch or no APIs."
  add_issue \
    "Failed to List APIs" \
    "$err_msg" \
    "1" \
    "Check if APIM name is correct or if any APIs exist."
  echo "$dependencies_json" > "$OUTPUT_FILE"
  exit 1
fi
rm -f "$apis_json_err"

api_count=$(echo "$apis_json" | jq '. | length')
echo "[INFO] Found $api_count APIs in APIM. Checking each serviceUrl..."

for (( i=0; i<api_count; i++ )); do
  api_name=$(echo "$apis_json" | jq -r ".[$i].name")
  service_url=$(echo "$apis_json" | jq -r ".[$i].serviceUrl // \"\"")
  if [[ -n "$service_url" && "$service_url" != "null" ]]; then
    echo "[INFO] API '$api_name' => serviceUrl: $service_url"
    add_dependency "$service_url" "BackendService"
  fi
done

###############################################################################
# 4) Summarize discovered dependencies so far
###############################################################################
echo "[INFO] Discovered dependencies so far:"
echo "$dependencies_json" | jq '.dependencies'

###############################################################################
# 5) Validate each discovered dependency
#    - If Key Vault => az keyvault show
#    - If BackendService => DNS + optional curl check
###############################################################################
SKIP_CONNECTIVITY_CHECK="${SKIP_CONNECTIVITY_CHECK:-0}"

deps_list=$(echo "$dependencies_json" | jq -c '.dependencies[]?')
for dep in $deps_list; do
  dep_name=$(echo "$dep" | jq -r '.name')
  dep_type=$(echo "$dep" | jq -r '.type')

  echo "[INFO] Validating dependency => $dep_name ($dep_type)"

  case "$dep_type" in
    "KeyVault")
      # Typically /subscriptions/.../resourceGroups/.../providers/Microsoft.KeyVault/vaults/<name>
      if ! az keyvault show --ids "$dep_name" -o none 2>kv_err.log; then
        err=$(cat kv_err.log)
        rm -f kv_err.log
        add_issue \
          "Key Vault Unavailable: $dep_name" \
          "$err" \
          "2" \
          "Check if the Key Vault is deleted/missing or your APIM has permissions."
      else
        rm -f kv_err.log
        echo "[INFO] Key Vault $dep_name is available."
      fi
      ;;
    "BackendService")
      # If it's an http(s) URL, parse domain for DNS check
      domain=$(echo "$dep_name" | sed -E 's|^https?://([^/]+)/?.*$|\1|')
      if [[ -z "$domain" || "$domain" == "$dep_name" ]]; then
        # fallback if we can't parse or it isn't a standard URL
        continue
      fi

      echo "[INFO] Doing DNS check for domain: $domain"
      if ! nslookup "$domain" >/dev/null 2>&1; then
        add_issue \
          "Backend Service DNS Error" \
          "Cannot resolve domain '$domain' from the environment running this script." \
          "3" \
          "Check your DNS or confirm the domain is correct in APIM serviceUrl."
      else
        echo "[INFO] DNS resolution OK for '$domain'."

        if [[ "$SKIP_CONNECTIVITY_CHECK" == "0" ]]; then
          echo "[INFO] Attempting short curl check to '$dep_name'..."
          # short 5-second timeout
          if ! curl -s --max-time 5 "$dep_name" >/dev/null; then
            add_issue \
              "Backend Service Unreachable" \
              "Curl to '$dep_name' failed. Possibly blocked by firewall or service is down." \
              "3" \
              "Check networking, firewall rules, or the backend availability."
          else
            echo "[INFO] '$dep_name' is reachable."
          fi
        fi
      fi
      ;;
    *)
      echo "[WARN] Unknown dependency type: $dep_type. No checks performed."
      ;;
  esac
done

###############################################################################
# 6) Write final JSON => { "dependencies": [...], "issues": [...] }
###############################################################################
echo "[INFO] Writing results to $OUTPUT_FILE"
echo "$dependencies_json" > "$OUTPUT_FILE"
echo "[INFO] Completed dependency inspection."
