#!/usr/bin/env bash
#
# Check APIM Key Vault Dependencies and Access Issues
#
# Usage:
#   export AZ_RESOURCE_GROUP="myResourceGroup"
#   export APIM_NAME="myApimInstance"
#   export RW_LOOKBACK_WINDOW="60"  # Optional, defaults to 60
#   # Optional: export AZURE_RESOURCE_SUBSCRIPTION_ID="your-subscription-id"
#   ./check_apim_keyvault.sh
#
# Description:
#   - Checks if APIM has Key Vault dependencies (certificates, secrets)
#   - If Key Vaults are referenced, checks access and recent audit logs
#   - Reports on access failures and certificate expiration issues
#   - If no Key Vault integration, notes it as informational

set -euo pipefail

###############################################################################
# 1) Subscription context & environment checks
###############################################################################
if [[ -z "${AZURE_RESOURCE_SUBSCRIPTION_ID:-}" ]]; then
    subscription=$(az account show --query "id" -o tsv)
    echo "AZURE_RESOURCE_SUBSCRIPTION_ID is not set. Using current subscription ID: $subscription"
else
    subscription="$AZURE_RESOURCE_SUBSCRIPTION_ID"
    echo "Using specified subscription ID: $subscription"
fi

echo "Switching to subscription ID: $subscription"
az account set --subscription "$subscription" || {
    echo "Failed to set subscription."
    exit 1
}

: "${AZ_RESOURCE_GROUP:?Must set AZ_RESOURCE_GROUP}"
: "${APIM_NAME:?Must set APIM_NAME}"

RW_LOOKBACK_WINDOW="${RW_LOOKBACK_WINDOW:-60}"
OUTPUT_FILE="apim_keyvault_issues.json"
issues_json='{"issues": []}'

echo "[INFO] Checking APIM Key Vault Dependencies..."
echo " APIM Name:     $APIM_NAME"
echo " ResourceGroup: $AZ_RESOURCE_GROUP"
echo " Time Period:   $RW_LOOKBACK_WINDOW minutes"

###############################################################################
# 2) Get APIM details and check for Key Vault references
###############################################################################
echo "[INFO] Retrieving APIM configuration..."

if ! apim_json=$(az apim show \
      --name "$APIM_NAME" \
      --resource-group "$AZ_RESOURCE_GROUP" \
      -o json 2>apim_show_err.log); then
    err_msg=$(cat apim_show_err.log)
    rm -f apim_show_err.log
    echo "ERROR: Could not retrieve APIM details."
    issues_json=$(echo "$issues_json" | jq \
        --arg t "Failed to Retrieve APIM Resource" \
        --arg d "$err_msg" \
        --arg s "1" \
        --arg n "Check APIM name/RG and permissions." \
        '.issues += [{
           "title": $t,
           "details": $d,
           "next_steps": $n,
           "severity": ($s | tonumber)
        }]')
    echo "$issues_json" > "$OUTPUT_FILE"
    exit 1
fi
rm -f apim_show_err.log

echo "[INFO] Checking for Key Vault references in APIM configuration..."

# Check hostname configurations for Key Vault certificate references
hostname_configs=$(echo "$apim_json" | jq -c '.hostnameConfigurations // []')
keyvault_refs=()

if [[ "$hostname_configs" != "[]" ]]; then
    echo "[INFO] Found hostname configurations. Checking for Key Vault references..."
    
    # Extract Key Vault references from certificate configurations
    while IFS= read -r config; do
        cert_source=$(echo "$config" | jq -r '.certificate.certificateSource // empty')
        if [[ "$cert_source" == "KeyVault" ]]; then
            keyvault_secret_id=$(echo "$config" | jq -r '.certificate.secretIdentifier // empty')
            if [[ -n "$keyvault_secret_id" ]]; then
                keyvault_refs+=("$keyvault_secret_id")
                echo "[INFO] Found Key Vault certificate reference: $keyvault_secret_id"
            fi
        fi
    done < <(echo "$hostname_configs" | jq -c '.[]')
fi

# Check if there are any Key Vault references
if [[ ${#keyvault_refs[@]} -eq 0 ]]; then
    echo "[INFO] No Key Vault dependencies found in APIM configuration."
    echo "$issues_json" > "$OUTPUT_FILE"
    exit 0
fi

echo "[INFO] Found ${#keyvault_refs[@]} Key Vault references in APIM"

###############################################################################
# 3) Check each Key Vault for access and recent audit logs
###############################################################################
unique_keyvaults=()

# Extract unique Key Vault names from references
for ref in "${keyvault_refs[@]}"; do
    # Parse Key Vault name from URL like https://mykv.vault.azure.net/secrets/cert/version
    if [[ "$ref" =~ ^https://([^.]+)\.vault\.azure\.net/ ]]; then
        kv_name="${BASH_REMATCH[1]}"
        if [[ ! " ${unique_keyvaults[@]} " =~ " ${kv_name} " ]]; then
            unique_keyvaults+=("$kv_name")
        fi
    fi
done

echo "[INFO] Found ${#unique_keyvaults[@]} unique Key Vault(s): ${unique_keyvaults[*]}"

# Check each Key Vault
for kv_name in "${unique_keyvaults[@]}"; do
    echo "[INFO] Checking Key Vault: $kv_name"
    
    # Try to get Key Vault details (tests basic access)
    if ! kv_details=$(az keyvault show --name "$kv_name" -o json 2>kv_err.log); then
        err_msg=$(cat kv_err.log)
        rm -f kv_err.log
        echo "[WARN] Cannot access Key Vault: $kv_name"
        
        if echo "$err_msg" | grep -q "does not exist"; then
            severity="2"  # Major issue - referenced Key Vault doesn't exist
            title="Referenced Key Vault Does Not Exist"
            next_steps="Key Vault '$kv_name' referenced by APIM but not found. Check if deleted or in different subscription."
        elif echo "$err_msg" | grep -q "Forbidden\|insufficient privileges"; then
            severity="3"  # Error - access denied
            title="Key Vault Access Denied"
            next_steps="APIM managed identity may lack permissions to access Key Vault '$kv_name'. Check access policies."
        else
            severity="3"  # Error - other access issue
            title="Key Vault Access Issue"
            next_steps="Cannot access Key Vault '$kv_name'. Check connectivity and permissions."
        fi
        
        issues_json=$(echo "$issues_json" | jq \
            --arg t "$title" \
            --arg d "Key Vault: $kv_name, Error: $err_msg" \
            --arg s "$severity" \
            --arg n "$next_steps" \
            '.issues += [{
               "title": $t,
               "details": $d,
               "next_steps": $n,
               "severity": ($s | tonumber)
            }]')
        continue
    fi
    rm -f kv_err.log
    
    kv_resource_id=$(echo "$kv_details" | jq -r '.id')
    echo "[INFO] Key Vault $kv_name is accessible"
    
    # Check Key Vault diagnostic settings and query logs if available
    kv_diag_settings=$(az monitor diagnostic-settings list \
        --resource "$kv_resource_id" -o json 2>/dev/null || echo "[]")
    
    if [[ "$kv_diag_settings" != "[]" ]]; then
        # Check if there's a Log Analytics workspace configured
        kv_workspace_id=$(echo "$kv_diag_settings" | jq -r '.[0].workspaceId // empty')
        
        if [[ -n "$kv_workspace_id" && "$kv_workspace_id" != "null" ]]; then
            echo "[INFO] Key Vault has diagnostic logging configured. Checking for access failures..."
            
            # Get workspace GUID
            if workspace_guid=$(az monitor log-analytics workspace show \
                  --ids "$kv_workspace_id" \
                  --query "customerId" -o tsv 2>/dev/null); then
                
                # Query for Key Vault access failures
                time_range="${RW_LOOKBACK_WINDOW}m"
                KV_AUDIT_QUERY="AzureDiagnostics
| where TimeGenerated >= ago($time_range)
| where ResourceId == \"$kv_resource_id\"
| where Category == \"AuditEvent\"
| where ResultType != \"Success\"
| where OperationName in (\"SecretGet\", \"CertificateGet\", \"KeyGet\")
| summarize FailureCount = count() by OperationName, ResultType, CallerIpAddress
| order by FailureCount desc"
                
                if kv_audit_output=$(az monitor log-analytics query \
                      --workspace "$workspace_guid" \
                      --analytics-query "$KV_AUDIT_QUERY" \
                      -o json 2>/dev/null); then
                    
                    failure_count=$(echo "$kv_audit_output" | jq '.tables[0].rows | length')
                    if [[ "$failure_count" -gt 0 ]]; then
                        echo "[INFO] Found $failure_count failure types in Key Vault audit logs"
                        
                        total_failures=0
                        for (( i=0; i<failure_count; i++ )); do
                            operation=$(echo "$kv_audit_output" | jq -r ".tables[0].rows[$i][0] // \"Unknown\"")
                            result_type=$(echo "$kv_audit_output" | jq -r ".tables[0].rows[$i][1] // \"Unknown\"")
                            caller_ip=$(echo "$kv_audit_output" | jq -r ".tables[0].rows[$i][2] // \"Unknown\"")
                            fail_count=$(echo "$kv_audit_output" | jq -r ".tables[0].rows[$i][3] // 0")
                            total_failures=$((total_failures + fail_count))
                        done
                        
                        if [[ "$total_failures" -gt 5 ]]; then  # Threshold
                            failure_details=$(echo "$kv_audit_output" | jq -c '.tables[0].rows')
                            issues_json=$(echo "$issues_json" | jq \
                                --arg t "Key Vault Access Failures Detected" \
                                --arg d "Key Vault: $kv_name, Total failures: $total_failures, Details: $failure_details" \
                                --arg s "3" \
                                --arg n "Investigate Key Vault access failures. Check APIM managed identity permissions and network connectivity." \
                                '.issues += [{
                                   "title": $t,
                                   "details": $d,
                                   "next_steps": $n,
                                   "severity": ($s | tonumber)
                                }]')
                        fi
                    fi
                fi
            fi
        else
            echo "[INFO] Key Vault diagnostic logging not configured for advanced analysis"
        fi
    else
        echo "[INFO] Key Vault has no diagnostic settings configured"
    fi
    
    # Check specific certificate/secret access that APIM uses
    for ref in "${keyvault_refs[@]}"; do
        if [[ "$ref" =~ ^https://${kv_name}\.vault\.azure\.net/secrets/([^/]+) ]]; then
            secret_name="${BASH_REMATCH[1]}"
            echo "[INFO] Testing access to secret: $secret_name"
            
            # Try to get the secret (just metadata, not the actual value)
            if ! az keyvault secret show --vault-name "$kv_name" --name "$secret_name" \
                  --query "attributes" -o json >/dev/null 2>secret_err.log; then
                err_msg=$(cat secret_err.log)
                rm -f secret_err.log
                
                if echo "$err_msg" | grep -q "SecretNotFound"; then
                    severity="2"  # Major - referenced secret doesn't exist
                    title="Referenced Key Vault Secret Not Found"
                    next_steps="Secret '$secret_name' referenced by APIM but not found in Key Vault '$kv_name'. Check certificate configuration."
                elif echo "$err_msg" | grep -q "Forbidden\|Access denied"; then
                    severity="3"  # Error - permission issue
                    title="Key Vault Secret Access Denied"
                    next_steps="APIM cannot access secret '$secret_name' in Key Vault '$kv_name'. Check access policies and managed identity permissions."
                else
                    severity="3"  # Error - other issue
                    title="Key Vault Secret Access Issue"
                    next_steps="Cannot access secret '$secret_name' in Key Vault '$kv_name'. Check configuration and connectivity."
                fi
                
                issues_json=$(echo "$issues_json" | jq \
                    --arg t "$title" \
                    --arg d "Secret: $secret_name, Key Vault: $kv_name, Error: $err_msg" \
                    --arg s "$severity" \
                    --arg n "$next_steps" \
                    '.issues += [{
                       "title": $t,
                       "details": $d,
                       "next_steps": $n,
                       "severity": ($s | tonumber)
                    }]')
            else
                rm -f secret_err.log
                echo "[INFO] Secret $secret_name is accessible"
            fi
        fi
    done
done

###############################################################################
# 4) Final JSON output
###############################################################################
echo "$issues_json" > "$OUTPUT_FILE"
echo "[INFO] APIM Key Vault dependency check complete. Results -> $OUTPUT_FILE" 