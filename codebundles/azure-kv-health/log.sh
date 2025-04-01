#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# REQUIRED ENV VARS:
#   AZURE_SUBSCRIPTION_ID
#   AZURE_RESOURCE_GROUP
#
# This script:
#   1) Lists all Key Vaults in the specified resource group
#   2) Checks their diagnostic settings for Log Analytics integration
#   3) Queries logs for each Key Vault with logging enabled
#   4) Outputs results in JSON format
# -----------------------------------------------------------------------------

: "${AZURE_SUBSCRIPTION_ID:?Must set AZURE_SUBSCRIPTION_ID}"
: "${AZURE_RESOURCE_GROUP:?Must set AZURE_RESOURCE_GROUP}"
: "${AZURE_SUBSCRIPTION_NAME:?Must set AZURE_SUBSCRIPTION_NAME}"

OUTPUT_FILE="kv_log_issues.json"
TEMP_LOG_FILE="kv_log_query_temp.json"
issues_json='{"issues": []}'

echo "Analyzing Key Vault Logs..."
echo "Subscription ID: $AZURE_SUBSCRIPTION_ID"
echo "Resource Group:  $AZURE_RESOURCE_GROUP"
echo "Subscription Name:  $AZURE_SUBSCRIPTION_NAME"

# Check if log-analytics extension is installed
if ! az extension show --name log-analytics &>/dev/null; then
    echo "Adding log-analytics extension..."
    az extension add -n log-analytics
fi

# Get list of Key Vaults
echo "Retrieving Key Vaults in resource group..."
if ! keyvaults=$(az keyvault list -g "$AZURE_RESOURCE_GROUP" --subscription "$AZURE_SUBSCRIPTION_ID" --query "[].{id:id,name:name, resourceGroup:resourceGroup}" -o json 2>kv_list_err.log); then
    err_msg=$(cat kv_list_err.log)
    rm -f kv_list_err.log
    
    echo "ERROR: Could not list Key Vaults."
    issues_json=$(echo "$issues_json" | jq \
        --arg title "Failed to List Key Vaults" \
        --arg details "$err_msg" \
        --arg severity "1" \
        --arg nextStep "Check if the resource group exists and you have the right CLI permissions." \
        '.issues += [{
           "title": $title,
           "details": $details,
           "next_step": $nextStep,
           "severity": ($severity | tonumber)
        }]')
    echo "$issues_json" > "$OUTPUT_FILE"
    exit 1
fi
rm -f kv_list_err.log

# Process each Key Vault
for row in $(echo "${keyvaults}" | jq -c '.[]'); do
    name=$(echo $row | jq -r '.name')
    resourceGroup=$(echo $row | jq -r '.resourceGroup')
    resource_id=$(echo $row | jq -r '.id')
    
    echo "Processing Key Vault: $name"
    
    # Get diagnostic settings
    diagnostics=$(az monitor diagnostic-settings list --resource "$resource_id" -o json 2>diag_err.log || true)

    if [[ -z "$diagnostics" || "$diagnostics" == "[]" ]]; then
        err_msg=$(cat diag_err.log)
        rm -f diag_err.log
        
        issues_json=$(echo "$issues_json" | jq \
            --arg title "No Diagnostic Settings Found for Key Vault $name" \
            --arg details "No diagnostic settings send logs to Log Analytics. $err_msg" \
            --arg severity "4" \
            --arg nextStep "Configure a diagnostic setting to forward Key Vault \`$name\` logs to Log Analytics in Resource Group \`$AZURE_RESOURCE_GROUP\`" \
            '.issues += [{
               "title": $title,
               "details": $details,
               "next_step": $nextStep,
               "severity": ($severity | tonumber)
             }]')
        continue
    fi
    rm -f diag_err.log

    # Check logging settings
    audit_enabled=$(echo "$diagnostics" | jq -r '.[0].logs[] | select(.categoryGroup == "audit") | .enabled // false')
    all_logs_enabled=$(echo "$diagnostics" | jq -r '.[0].logs[] | select(.categoryGroup == "allLogs") | .enabled // false')
    
    if [[ "$audit_enabled" == "true" || "$all_logs_enabled" == "true" ]]; then
        workspace_id=$(echo "$diagnostics" | jq -r '.[0].workspaceId')
        
        if [[ -z "$workspace_id" || "$workspace_id" == "null" ]]; then
            issues_json=$(echo "$issues_json" | jq \
                --arg title "No Log Analytics Workspace Setting for Key Vault $name" \
                --arg details "Diagnostic settings exist but no Log Analytics workspace is configured." \
                --arg severity "1" \
                --arg nextStep "Configure at least one setting to send logs to Log Analytics for Key Vault \`$name\` in Resource Group \`$AZURE_RESOURCE_GROUP\`" \
                '.issues += [{
                   "title": $title,
                   "details": $details,
                   "next_step": $nextStep,
                   "severity": ($severity | tonumber)
                 }]')
            continue
        fi

        # Get workspace GUID
        if ! WORKSPACE_GUID=$(az monitor log-analytics workspace show \
            --ids "$workspace_id" \
            --query "customerId" -o tsv 2>la_guid_err.log); then
            err_msg=$(cat la_guid_err.log)
            rm -f la_guid_err.log
            
            issues_json=$(echo "$issues_json" | jq \
                --arg title "Failed to Get Workspace GUID for Key Vault $name" \
                --arg details "$err_msg" \
                --arg severity "1" \
                --arg nextStep "Check if you have Reader or higher role on the workspace resource. Also verify it is a valid workspace ID." \
                '.issues += [{
                   "title": $title,
                   "details": $details,
                   "next_step": $nextStep,
                   "severity": ($severity | tonumber)
                 }]')
            continue
        fi
        rm -f la_guid_err.log

        # Run log query
        if ! log_query=$(az monitor log-analytics query \
            --workspace "$WORKSPACE_GUID" \
            --analytics-query "AzureDiagnostics | where ResourceProvider == 'MICROSOFT.KEYVAULT' and Resource =~ '$name' | order by TimeGenerated desc" \
            -o json 2>la_query_err.log); then
            err_msg=$(cat la_query_err.log)
            rm -f la_query_err.log
            
            issues_json=$(echo "$issues_json" | jq \
                --arg title "Failed Log Analytics Query for Key Vault $name" \
                --arg details "$err_msg" \
                --arg severity "1" \
                --arg nextStep "Verify query syntax, aggregator, or ensure the workspace has logs." \
                '.issues += [{
                   "title": $title,
                   "details": $details,
                   "next_step": $nextStep,
                   "severity": ($severity | tonumber)
                 }]')
            continue
        fi
        rm -f la_query_err.log
        
        # Save log query to temp file
        echo "$log_query" > "$TEMP_LOG_FILE"

        # Analyze log results and create next steps
        if [[ -s "$TEMP_LOG_FILE" ]]; then
            # Check for authentication failures
            auth_failures=$(jq -r '.[] | select(.httpStatusCode_d == "401" or .httpStatusCode_d == "403")' "$TEMP_LOG_FILE")
            if [[ -n "$auth_failures" ]]; then
                # Extract unique entries based on operation name and include additional fields
                details_json=$(echo "$auth_failures" | jq -s '
                    group_by(.OperationName) | 
                    map({
                        operation: .[0].OperationName,
                        httpStatusCode: .[0].httpStatusCode_d,
                        clientInfo: .[0].clientInfo_s,
                        id: .[0].id_s,
                        identityType: .[0].identity_claim_idtyp_s,
                        identity: (.[0].identity_claim_upn_s // .[0].identity_claim_unique_name_s // "Unknown"),
                        ip: .[0].CallerIPAddress,
                        timestamp: .[0].TimeGenerated,
                        requestUri: .[0].requestUri_s,
                        httpMethod: .[0].httpMethod_s,
                        resultType: .[0].ResultType,
                        resource: .[0].Resource,
                        correlationId: .[0].CorrelationId,
                        objectId: .[0].identity_claim_http_schemas_microsoft_com_identity_claims_objectidentifier_g,
                        tenantId: .[0].properties_tenantId_g,
                        vaultName: .[0].eventGridEventProperties_data_VaultName_s,
                        userAgent: .[0].userAgent_s,
                        resultDescription: .[0].ResultDescription,
                        count: length
                    })
                ')
                nextStep=$(cat <<EOF
Verify identity permissions in access policies and RBAC in resource group \`$AZURE_RESOURCE_GROUP\` in subscription \`$AZURE_SUBSCRIPTION_NAME\`
Check if IP is allowed in network rules in resource group \`$AZURE_RESOURCE_GROUP\` in subscription \`$AZURE_SUBSCRIPTION_NAME\`
Review client application details in resource group \`$AZURE_RESOURCE_GROUP\` in subscription \`$AZURE_SUBSCRIPTION_NAME\`
Check if tenant ID matches in resource group \`$AZURE_RESOURCE_GROUP\` in subscription \`$AZURE_SUBSCRIPTION_NAME\`
Verify object ID has correct permissions in resource group \`$AZURE_RESOURCE_GROUP\` in subscription \`$AZURE_SUBSCRIPTION_NAME\`
If unauthorized, consider blocking IP and reviewing client applications in resource group \`$AZURE_RESOURCE_GROUP\` in subscription \`$AZURE_SUBSCRIPTION_NAME\`
EOF
)
                issues_json=$(echo "$issues_json" | jq \
                    --arg title "Authentication Failures Detected in Key Vault $name in resource group \`$AZURE_RESOURCE_GROUP\` in subscription \`$AZURE_SUBSCRIPTION_NAME\`" \
                    --argjson details "$details_json" \
                    --arg severity "3" \
                    --arg nextStep "$nextStep" \
                    '.issues += [{
                    "title": $title,
                    "details": $details,
                    "next_step": $nextStep,
                    "severity": ($severity | tonumber)
                    }]')
            fi

#             # Check for other HTTP failures
#             other_failures=$(jq -r '.[] | select((.httpStatusCode_d >= "400" and .httpStatusCode_d < "600") and (.httpStatusCode_d != "401" and .httpStatusCode_d != "403"))' "$TEMP_LOG_FILE")
#             if [[ -n "$other_failures" ]]; then
#                 # Extract unique entries based on operation name and include additional fields
#                 details_json=$(echo "$other_failures" | jq -s '
#                     group_by(.OperationName) | 
#                     map({
#                         operation: .[0].OperationName,
#                         httpStatusCode: .[0].httpStatusCode_d,
#                         clientInfo: .[0].clientInfo_s,
#                         id: .[0].id_s,
#                         ip: .[0].CallerIPAddress,
#                         timestamp: .[0].TimeGenerated,
#                         requestUri: .[0].requestUri_s,
#                         httpMethod: .[0].httpMethod_s,
#                         resultType: .[0].ResultType,
#                         resource: .[0].Resource,
#                         correlationId: .[0].CorrelationId,
#                         vaultName: .[0].eventGridEventProperties_data_VaultName_s,
#                         userAgent: .[0].userAgent_s,
#                         resultDescription: .[0].ResultDescription,
#                         count: length
#                     })
#                 ')
#                 nextStep=$(cat <<EOF
# Verify request parameters and payload format for malformed or invalid inputs in resource group \`$AZURE_RESOURCE_GROUP\` in subscription \`$AZURE_SUBSCRIPTION_NAME\`
# Check for missing or incorrect resource paths and identifiers in resource group \`$AZURE_RESOURCE_GROUP\` in subscription \`$AZURE_SUBSCRIPTION_NAME\`
# Investigate concurrent operations that may cause resource conflicts in resource group \`$AZURE_RESOURCE_GROUP\` in subscription \`$AZURE_SUBSCRIPTION_NAME\`
# Review throttling and rate limiting configurations in resource group \`$AZURE_RESOURCE_GROUP\` in subscription \`$AZURE_SUBSCRIPTION_NAME\`
# Validate service health and maintenance windows in resource group \`$AZURE_RESOURCE_GROUP\` in subscription \`$AZURE_SUBSCRIPTION_NAME\`
# Check for internal service errors and unexpected failures in resource group \`$AZURE_RESOURCE_GROUP\` in subscription \`$AZURE_SUBSCRIPTION_NAME\`
# EOF
# )
#                 issues_json=$(echo "$issues_json" | jq \
#                     --arg title "HTTP Failures Detected in Key Vault $name in resource group \`$AZURE_RESOURCE_GROUP\` in subscription \`$AZURE_SUBSCRIPTION_NAME\`" \
#                     --argjson details "$details_json" \
#                     --arg severity "2" \
#                     --arg nextStep "$nextStep" \
#                     '.issues += [{
#                     "title": $title,
#                     "details": $details,
#                     "next_step": $nextStep,
#                     "severity": ($severity | tonumber)
#                     }]')
#             fi

            # Check for expired secrets/keys
            expired_items=$(jq -r '.[] | select((.secretProperties_attributes_exp_d != "None" and .secretProperties_attributes_exp_d < now) or (.keyProperties_attributes_exp_d != "None" and .keyProperties_attributes_exp_d < now))' "$TEMP_LOG_FILE")
            if [[ -n "$expired_items" ]]; then
                # Extract more detailed fields for troubleshooting
                details_json=$(echo "$expired_items" | jq -s '
                    map({
                        name: .id_s,
                        expiry: (.secretProperties_attributes_exp_d // .keyProperties_attributes_exp_d),
                        type: (if .secretProperties_attributes_exp_d then "secret" else "key" end),
                        created: (.secretProperties_attributes_created_d // .keyProperties_attributes_created_d),
                        enabled: (.secretProperties_attributes_enabled_b // .keyProperties_attributes_enabled_b),
                        vaultName: .eventGridEventProperties_data_VaultName_s,
                        resourceGroup: .resource_resourceGroupName_s,
                        subscriptionId: .resource_subscriptionId_g,
                        lastAccess: (.secretProperties_attributes_updated_d // .keyProperties_attributes_updated_d),
                        operations: (.keyProperties_operations_s // "N/A")
                    })
                ')
                
                issues_json=$(echo "$issues_json" | jq \
                    --arg title "Expired Secrets/Keys Found in Key Vault $name" \
                    --argjson details "$details_json" \
                    --arg severity "3" \
                    --arg nextStep "1. Review and rotate expired secrets/keys. 2. Check last access time to determine usage. 3. Verify if keys/secrets are still enabled. 4. Consider implementing automatic rotation. 5. Review operations history to understand usage patterns. 6. Check if associated resources still need these credentials." \
                    '.issues += [{
                       "title": $title,
                       "details": $details,
                       "next_step": $nextStep,
                       "severity": ($severity | tonumber)
                     }]')
            fi
        fi
        rm -f "$TEMP_LOG_FILE"
    fi
done

# Write final JSON
echo "$issues_json" > "$OUTPUT_FILE"
echo "Key Vault log analysis completed. Saved results to $OUTPUT_FILE"