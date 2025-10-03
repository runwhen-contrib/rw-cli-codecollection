#!/usr/bin/env bash
#
# Verify APIM Policy Configurations
# For APIM ${APIM_NAME} in Resource Group ${AZ_RESOURCE_GROUP}
#
# Usage:
#   export AZ_RESOURCE_GROUP="myResourceGroup"
#   export APIM_NAME="myApimInstance"
#   # Optionally: export AZURE_RESOURCE_SUBSCRIPTION_ID="sub-id"
#   ./verify_apim_policies.sh
#
# Description:
#   1) Retrieves the APIM resource ID
#   2) Lists all products, APIs, and operations
#   3) Fetches the policy (XML) at each level (global, product, API, operation)
#   4) Checks for key tags (set-backend-service, rate-limit, rewrite-uri, etc.)
#   5) Flags potential misconfigurations
#   6) Writes results to apim_policy_issues.json => { "issues": [...] }

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

###############################################################################
# 1) Subscription context
###############################################################################
if [ -z "${AZURE_RESOURCE_SUBSCRIPTION_ID:-}" ]; then
  subscription=$(az account show --query "id" -o tsv)
  echo "AZURE_RESOURCE_SUBSCRIPTION_ID is not set. Using current subscription ID: $subscription"
else
  subscription="$AZURE_RESOURCE_SUBSCRIPTION_ID"
  echo "Using specified subscription ID: $subscription"
fi
az account set --subscription "$subscription"

: "${AZ_RESOURCE_GROUP:?Must set AZ_RESOURCE_GROUP}"
: "${APIM_NAME:?Must set APIM_NAME}"

OUTPUT_FILE="apim_policy_issues.json"
issues_json='{"issues": []}'

echo "[INFO] Verifying APIM Policy Configurations for '$APIM_NAME' in RG '$AZ_RESOURCE_GROUP'..."

###############################################################################
# 2) Retrieve APIM resource ID
###############################################################################
apim_id=""
if ! apim_id=$(az apim show \
      --name "$APIM_NAME" \
      --resource-group "$AZ_RESOURCE_GROUP" \
      --query "id" -o tsv 2>apim_show_err.log); then
  err_msg=$(cat apim_show_err.log)
  rm -f apim_show_err.log
  echo "ERROR: Could not fetch APIM resource ID."
  issues_json=$(echo "$issues_json" | jq \
    --arg t "Failed to Retrieve APIM Resource ID" \
    --arg d "$err_msg" \
    --arg s "1" \
    --arg n "Check APIM name and RG or your permissions." \
    '.issues += [{
       "title": $t, "details": $d, "next_steps": $n, "severity": ($s|tonumber)
    }]')
  echo "$issues_json" > "$OUTPUT_FILE"
  exit 1
fi
rm -f apim_show_err.log
if [[ -z "$apim_id" ]]; then
  echo "[ERROR] No resource ID returned. Possibly APIM doesn't exist."
  issues_json=$(echo "$issues_json" | jq \
    --arg t "APIM Resource Not Found" \
    --arg d "az apim show returned an empty ID." \
    --arg s "1" \
    --arg n "Confirm APIM name, resource group, or create APIM instance." \
    '.issues += [{
       "title": $t, "details": $d, "next_steps": $n, "severity": ($s|tonumber)
    }]')
  echo "$issues_json" > "$OUTPUT_FILE"
  exit 1
fi
echo "[INFO] APIM Resource ID: $apim_id"

###############################################################################
# 3) Fetch the Global (Service-Level) Policy
#    We'll call the ARM endpoint for the 'policies/policy' subresource.
###############################################################################
service_policy_url="https://management.azure.com${apim_id}/policies/policy?api-version=2022-08-01"
echo "[INFO] Fetching service-level (global) policy..."
service_policy_xml=""
if ! service_policy_xml=$(az rest --method get --url "$service_policy_url" -o tsv --query "properties.value" 2>svc_policy_err.log || true); then
  echo "[WARN] Could not retrieve global APIM policy."
fi
rm -f svc_policy_err.log

# We'll parse the XML if present
if [[ -n "$service_policy_xml" ]]; then
  # Basic check for key tags
  # e.g. if there's no <set-backend-service>
  if ! echo "$service_policy_xml" | grep -iq "<set-backend-service"; then
    issues_json=$(echo "$issues_json" | jq \
      --arg t "Global Policy Missing set-backend-service" \
      --arg d "No <set-backend-service> tag found in service-level policy." \
      --arg s "4" \
      --arg n "Add <set-backend-service> or confirm the policy is intended if all backends are set at API-level." \
      '.issues += [{
         "title": $t, "details": $d, "next_steps": $n, "severity": ($s|tonumber)
       }]')
  fi
  # e.g. check for rate-limit
  if ! echo "$service_policy_xml" | grep -iq "<rate-limit"; then
    issues_json=$(echo "$issues_json" | jq \
      --arg t "Global Policy Missing rate-limit" \
      --arg d "No <rate-limit> found. Possibly you rely on product-level or API-level rate-limits." \
      --arg s "4" \
      --arg n "Confirm no global limit is needed for APIM '$APIM_NAME' in RG '$AZ_RESOURCE_GROUP'." \
      '.issues += [{
         "title": $t, "details": $d, "next_steps": $n, "severity": ($s|tonumber)
       }]')
  fi
  # Additional checks can go here
else
  echo "[WARN] Global APIM policy not found or empty."
fi

###############################################################################
# 4) List Products, APIs, and Operations
###############################################################################
# We'll gather a list of Products, then for each Product => fetch policy
# We'll gather a list of APIs, then for each => fetch policy
# Then each API => list operations => fetch operation-level policy
###############################################################################

echo "[INFO] Listing products..."
products_json=$(az rest --method get --url "https://management.azure.com${apim_id}/products?api-version=2022-08-01" -o json || echo "{}")
# We'll parse .value[], each product => name => fetch policy
product_count=$(echo "$products_json" | jq '.value | length' 2>/dev/null || echo 0)

echo "[INFO] Listing APIs..."
apis_json=$(az rest --method get --url "https://management.azure.com${apim_id}/apis?api-version=2022-08-01" -o json || echo "{}")
api_count=$(echo "$apis_json" | jq '.value | length' 2>/dev/null || echo 0)

###############################################################################
# 4a) Check each Product's policy
###############################################################################
for (( i=0; i<product_count; i++ )); do
  product_name=$(echo "$products_json" | jq -r ".value[$i].name")
  product_id=$(echo "$products_json" | jq -r ".value[$i].id")
  if [[ "$product_id" == "null" || -z "$product_id" ]]; then
    continue
  fi

  # e.g. "https://management.azure.com/subs/.../service/<apimName>/products/<productName>/policies/policy?api-version=2022-08-01"
  product_policy_url="https://management.azure.com${product_id}/policies/policy?api-version=2022-08-01"

  product_policy_xml=$(az rest --method get --url "$product_policy_url" -o tsv --query "properties.value" 2>/dev/null || echo "")
  if [[ -z "$product_policy_xml" ]]; then
    continue
  fi

  # Example check: if no <rewrite-uri> found, maybe the product policy is incomplete
  if ! echo "$product_policy_xml" | grep -iq "<rewrite-uri"; then
    issues_json=$(echo "$issues_json" | jq \
      --arg t "Product '$product_name' Missing rewrite-uri" \
      --arg d "Policy doesn't contain <rewrite-uri>." \
      --arg s "4" \
      --arg n "Confirm if rewriting is needed at product-level or if you do it at API-level." \
      '.issues += [{
         "title": $t, "details": $d, "next_steps": $n, "severity": ($s|tonumber)
       }]')
  fi
  # More checks as needed...
done

###############################################################################
# 4b) Check each API's policy, then each operation's policy
###############################################################################
for (( i=0; i<api_count; i++ )); do
  api_name=$(echo "$apis_json" | jq -r ".value[$i].name")
  api_id=$(echo "$apis_json" | jq -r ".value[$i].id")
  if [[ "$api_id" == "null" || -z "$api_id" ]]; then
    continue
  fi

  # API-level policy
  api_policy_url="https://management.azure.com${api_id}/policies/policy?api-version=2022-08-01"
  api_policy_xml=$(az rest --method get --url "$api_policy_url" -o tsv --query "properties.value" 2>/dev/null || echo "")
  if [[ -z "$api_policy_xml" ]]; then
    # It's valid to have no explicit policy at this level
    continue
  fi

  # Example: Check for <authentication-managed-identity> if we expect managed ID auth at the API level
  if ! echo "$api_policy_xml" | grep -iq "<authentication-managed-identity"; then
    issues_json=$(echo "$issues_json" | jq \
      --arg t "API '$api_name' Missing Managed Identity Auth" \
      --arg d "No <authentication-managed-identity> found. Possibly you are using other auth methods." \
      --arg s "4" \
      --arg n "Confirm if you require managed identity for API '$api_name' in APIM '$APIM_NAME'." \
      '.issues += [{
         "title": $t, "details": $d, "next_steps": $n, "severity": ($s|tonumber)
       }]')
  fi

  # Then list the operations for this API
  api_ops_json=$(az rest --method get --url "https://management.azure.com${api_id}/operations?api-version=2022-08-01" -o json || echo "{}")
  op_count=$(echo "$api_ops_json" | jq '.value | length' 2>/dev/null || echo 0)
  for (( j=0; j<op_count; j++ )); do
    op_name=$(echo "$api_ops_json" | jq -r ".value[$j].name")
    op_id=$(echo "$api_ops_json" | jq -r ".value[$j].id")

    # fetch operation-level policy
    op_policy_url="https://management.azure.com${op_id}/policies/policy?api-version=2022-08-01"
    op_policy_xml=$(az rest --method get --url "$op_policy_url" -o tsv --query "properties.value" 2>/dev/null || echo "")
    if [[ -z "$op_policy_xml" ]]; then
      continue
    fi

    # Example check: if no <set-backend-service> => possible misconfig
    if ! echo "$op_policy_xml" | grep -iq "<set-backend-service"; then
      issues_json=$(echo "$issues_json" | jq \
        --arg t "Operation '$op_name' Missing set-backend-service" \
        --arg d "Operation policy does not specify <set-backend-service>." \
        --arg s "4" \
        --arg n "Check if you rely on global or API-level service setting for op '$op_name' in API '$api_name'." \
        '.issues += [{
           "title": $t, "details": $d, "next_steps": $n, "severity": ($s|tonumber)
         }]')
    fi
    # Additional checks here...
  done
done

###############################################################################
# 5) Write results to apim_policy_issues.json
###############################################################################
echo "$issues_json" > "$OUTPUT_FILE"
echo "[INFO] APIM policy verification complete. Results -> $OUTPUT_FILE"
