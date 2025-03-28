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

OUTPUT_FILE="kv_log_issues.json"
issues_json='{"issues": []}'

echo "Analyzing Key Vault Logs..."
echo "Subscription ID: $AZURE_SUBSCRIPTION_ID"
echo "Resource Group:  $AZURE_RESOURCE_GROUP"

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
    fi
done

# Write final JSON
echo "$issues_json" > "$OUTPUT_FILE"
echo "Key Vault log analysis completed. Saved results to $OUTPUT_FILE"