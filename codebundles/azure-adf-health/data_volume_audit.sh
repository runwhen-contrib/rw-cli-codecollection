#!/bin/bash
set -euo pipefail

# -----------------------------------------------------------------------------
# REQUIRED ENV VARS:
#   AZURE_SUBSCRIPTION_ID
#   AZURE_RESOURCE_GROUP
#   THRESHOLD_MB - Threshold in MB for heavy read/write operations
# -----------------------------------------------------------------------------

: "${AZURE_SUBSCRIPTION_ID:?Must set AZURE_SUBSCRIPTION_ID}"
: "${AZURE_RESOURCE_GROUP:?Must set AZURE_RESOURCE_GROUP}"
: "${THRESHOLD_MB:?Must set THRESHOLD_MB}"

subscription_id="$AZURE_SUBSCRIPTION_ID"
resource_group="$AZURE_RESOURCE_GROUP"
output_file="data_volume_audit.json"
audit_json='{"data_volume_alerts": []}'

echo "Checking Data Factories for heavy data operations..."
echo "Resource Group: $resource_group"
echo "Subscription ID: $subscription_id"
echo "Threshold: $THRESHOLD_MB MB"

# Configure Azure CLI to explicitly allow or disallow preview extensions
az config set extension.dynamic_install_allow_preview=true

# Check and install datafactory extension if needed
echo "Checking for datafactory extension..."
if ! az extension show --name datafactory > /dev/null; then
    echo "Installing datafactory extension..."
    az extension add --name datafactory || { echo "Failed to install datafactory extension."; exit 1; }
fi

# Get all Data Factories in the resource group
datafactories=$(az datafactory list -g "$resource_group" --subscription "$subscription_id" -o json)

if [[ -z "$datafactories" || "$datafactories" == "[]" ]]; then
    echo "No Data Factories found in resource group $resource_group"
    echo "$audit_json" > "$output_file"
    exit 0
fi

for row in $(echo "$datafactories" | jq -c '.[]'); do
    df_name=$(echo "$row" | jq -r '.name')
    df_id=$(echo "$row" | jq -r '.id')
    df_rg=$(echo "$row" | jq -r '.resourceGroup')
    df_url="https://adf.azure.com/en/monitoring/pipelineruns?factory=${df_id}"

    echo "Processing Data Factory: $df_name"

    # Get diagnostic settings
    diagnostics=$(az monitor diagnostic-settings list --resource "$df_id" -o json 2>diag_err.log || true)
    
    if [[ -z "$diagnostics" || "$diagnostics" == "[]" ]]; then
        err_msg=$(cat diag_err.log)
        rm -f diag_err.log

        audit_json=$(echo "$audit_json" | jq \
            --arg title "No Diagnostic Settings for Data Factory $df_name" \
            --arg details "$err_msg" \
            --arg severity "4" \
            --arg nextStep "Enable diagnostics and configure Log Analytics" \
            --arg expected "Diagnostic settings should be enabled" \
            --arg resource_url "$df_url" \
            --arg reproduce_hint "az monitor diagnostic-settings list --resource \"$df_id\"" \
            --arg actual "Diagnostic settings not enabled" \
            --arg reproduce_hint "az monitor diagnostic-settings list --resource \"$df_id\"" \
            '.data_volume_alerts += [{
                "title": $title,
                "details": $details,
                "next_step": $nextStep,
                "actual": $actual,
                "expected": $expected,
                "severity": ($severity | tonumber),
                "resource_url": $resource_url,
                "reproduce_hint": $reproduce_hint
            }]')
        continue
    fi
    rm -f diag_err.log

    # Extract Log Analytics workspace ID
    workspace_id=$(echo "$diagnostics" | jq -r '.[0].workspaceId // empty')

    # Count how many ActivityRuns logs are enabled
    enabled_activity_runs_count=$(echo "$diagnostics" | jq '[.[0].logs[] | select(.category == "ActivityRuns" and .enabled == true)] | length')

    if [[ "$enabled_activity_runs_count" -eq 0 ]]; then
        audit_json=$(echo "$audit_json" | jq \
            --arg title "ActivityRuns Logging Disabled in Data Factory $df_name" \
            --arg details "ActivityRuns logging category is required for data volume monitoring" \
            --arg severity "4" \
            --arg nextStep "Enable ActivityRuns logging in diagnostic settings" \
            --arg expected "ActivityRuns logging should be enabled" \
            --arg resource_url "$df_url" \
            --arg actual "ActivityRuns logging is disabled" \
            --arg reproduce_hint "az monitor diagnostic-settings list --resource \"$df_id\" --subscription \"$subscription_id\" --output json" \
            '.data_volume_alerts += [{
                "title": $title,
                "details": $details,
                "next_step": $nextStep,
                "actual": $actual,
                "expected": $expected,
                "severity": ($severity | tonumber),
                "resource_url": $resource_url,
                "reproduce_hint": $reproduce_hint
            }]')
        continue
    fi

    if [[ -z "$workspace_id" || "$workspace_id" == "null" ]]; then
        audit_json=$(echo "$audit_json" | jq \
            --arg title "No Log Analytics Workspace for $df_name" \
            --arg details "Diagnostics are configured but no workspace is defined" \
            --arg severity "4" \
            --arg nextStep "Configure Log Analytics workspace" \
            --arg expected "Log Analytics workspace should be configured" \
            --arg resource_url "$df_url" \
            --arg actual "No Log Analytics workspace configured" \
            --arg reproduce_hint "az monitor log-analytics workspace show --ids \"$workspace_id\" --query customerId -o tsv" \
            '.data_volume_alerts += [{
                "title": $title,
                "details": $details,
                "next_step": $nextStep,
                "actual": $actual,
                "expected": $expected,
                "severity": ($severity | tonumber),
                "resource_url": $resource_url,
                "reproduce_hint": $reproduce_hint
            }]')
        continue
    fi

    # Get customer ID (GUID) for the workspace
    if ! workspace_guid=$(az monitor log-analytics workspace show --ids "$workspace_id" --query "customerId" -o tsv 2>guid_err.log); then
        err_msg=$(cat guid_err.log)
        rm -f guid_err.log

        audit_json=$(echo "$audit_json" | jq \
            --arg title "Failed to get Log Analytics workspace GUID for $df_name in resource group \`$resource_group\`" \
            --arg details "$err_msg" \
            --arg severity "4" \
            --arg nextStep "Verify workspace permissions" \
            --arg expected "Should be able to query workspace information" \
            --arg resource_url "$df_url" \
            --arg actual "Failed to get workspace GUID" \
            --arg reproduce_hint "az monitor log-analytics workspace show --ids \"$workspace_id\" --query customerId -o tsv" \
            '.data_volume_alerts += [{
                "title": $title,
                "details": $details,
                "next_step": $nextStep,
                "actual": $actual,
                "expected": $expected,
                "severity": ($severity | tonumber),
                "resource_url": $resource_url,
                "reproduce_hint": $reproduce_hint
            }]')
        continue
    fi
    rm -f guid_err.log

    # KQL Query to check for heavy data operations
    kql_query=$(cat <<EOF
let threshold = $THRESHOLD_MB;
AzureDiagnostics
| where ResourceProvider == "MICROSOFT.DATAFACTORY"
| where Category == "ActivityRuns"
| where status_s == "Succeeded"
| where Resource =~ "$df_name"
| top 1 by TimeGenerated desc
| extend isHeavyRead = toint(Output_dataRead_d > threshold), isHeavyWrite = toint(Output_dataWritten_d > threshold)
| project TimeGenerated, pipelineName_s, pipelineRunId_g, Output_dataRead_d, Output_dataWritten_d, isHeavyRead, isHeavyWrite, ResourceId
EOF
)

    echo "Querying data volume metrics for $df_name..."
    if ! volume_data=$(az monitor log-analytics query \
        --workspace "$workspace_guid" \
        --analytics-query "$kql_query" \
        --subscription "$subscription_id" \
        --output json 2>volume_query_err.log); then
        err_msg=$(cat volume_query_err.log)
        rm -f volume_query_err.log
        
        audit_json=$(echo "$audit_json" | jq \
            --arg title "Log Analytics Query Failed for $df_name" \
            --arg details "$err_msg" \
            --arg severity "4" \
            --arg nextStep "Verify workspace permissions or check if diagnostics have been sending data" \
            --arg expected "Log Analytics query should be successful" \
            --arg resource_url "$df_url" \
            --arg actual "Log Analytics query failed" \
            --arg reproduce_hint "az monitor log-analytics query --workspace \"$workspace_guid\" --analytics-query '$kql_query' --subscription \"$subscription_id\" --output json" \
            '.data_volume_alerts += [{
                "title": $title,
                "details": $details,
                "next_step": $nextStep,
                "actual": $actual,
                "expected": $expected,
                "severity": ($severity | tonumber),
                "resource_url": $resource_url,
                "reproduce_hint": $reproduce_hint
            }]')
        continue
    fi
    rm -f volume_query_err.log

    if ! echo "${volume_data}" | jq empty 2>/dev/null; then
        echo "Error: Invalid JSON in volume_data"
        continue
    fi

    while read -r activity; do
        pipeline_name=$(echo "$activity" | jq -r '.pipelineName_s')
        run_id=$(echo "$activity" | jq -r '.pipelineRunId_g')
        data_read=$(echo "$activity" | jq -r '.Output_dataRead_d')
        data_written=$(echo "$activity" | jq -r '.Output_dataWritten_d')
        is_heavy_read=$(echo "$activity" | jq -r '.isHeavyRead')
        is_heavy_write=$(echo "$activity" | jq -r '.isHeavyWrite')

        if [[ "$is_heavy_read" -eq 1 || "$is_heavy_write" -eq 1 ]]; then
            audit_json=$(echo "$audit_json" | jq \
                --arg title "Large Data Operation Detected in Pipeline \`$pipeline_name\` in resource group \`$resource_group\`" \
                --arg details $activity \
                --arg severity "4" \
                --arg nextStep "Review and adjust ADF Integration Runtime configuration in resource group \`$resource_group\`" \
                --arg name "$pipeline_name" \
                --arg expected "ADF pipeline \`$pipeline_name\` data operations should be below ${THRESHOLD_MB}MB threshold in resource group \`$resource_group\`" \
                --arg actual "ADF pipeline \`$pipeline_name\` has large data operations in resource group \`$resource_group\`" \
                --arg resource_url "$df_url" \
                --arg run_id "$run_id" \
                --arg reproduce_hint "az monitor log-analytics query --workspace \"$workspace_guid\" --analytics-query '$kql_query' --subscription \"$subscription_id\" --output json" \
                '.data_volume_alerts += [{
                    "title": $title,
                    "details": $details,
                    "next_step": $nextStep,
                    "actual": $actual,
                    "severity": ($severity | tonumber),
                    "name": $name,
                    "resource_url": $resource_url,
                    "expected": $expected,
                    "reproduce_hint": $reproduce_hint,
                    "run_id": $run_id
                }]')
        fi
    done < <(echo "$volume_data" | jq -c '.[]')
done

# Write output to file
echo "Final JSON contents:"
echo "$audit_json" | jq
echo "$audit_json" > "$output_file"
echo "Data volume audit completed. Results saved to $output_file"