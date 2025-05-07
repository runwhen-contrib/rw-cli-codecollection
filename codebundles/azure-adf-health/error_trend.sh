#!/bin/bash
set -euo pipefail

# -----------------------------------------------------------------------------
# REQUIRED ENV VARS:
#   AZURE_SUBSCRIPTION_ID
#   AZURE_RESOURCE_GROUP
#   LOOKBACK_PERIOD (optional, default: 7d)
# -----------------------------------------------------------------------------

: "${AZURE_SUBSCRIPTION_ID:?Must set AZURE_SUBSCRIPTION_ID}"
: "${AZURE_RESOURCE_GROUP:?Must set AZURE_RESOURCE_GROUP}"
: "${LOOKBACK_PERIOD:?Must set LOOKBACK_PERIOD:=7d}"
subscription_id="$AZURE_SUBSCRIPTION_ID"
resource_group="$AZURE_RESOURCE_GROUP"
output_file="error_trend.json"
error_trends_json='{"error_trends": []}'

echo "Checking Data Factories and retrieving failed pipeline runs..."
echo "Resource Group: $resource_group"
echo "Subscription ID: $subscription_id"
# Configure Azure CLI to explicitly allow or disallow preview extensions
az config set extension.dynamic_install_allow_preview=true
# Check and install datafactory extension if needed
echo "Checking for datafactory extension..."
if ! az extension show --name datafactory > /dev/null; then
    echo "Installing datafactory extension..."
    az extension add --name datafactory || { echo "Failed to install datafactory extension."; exit 1; }
fi
# set -x
# Get all Data Factories in the resource group
datafactories=$(az datafactory list -g "$resource_group" --subscription "$subscription_id" -o json)

if [[ -z "$datafactories" || "$datafactories" == "[]" ]]; then
    echo "No Data Factories found in resource group $resource_group"
    echo "$error_trends_json" > "$output_file"
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

        error_trends_json=$(echo "$error_trends_json" | jq \
            --arg title "No Diagnostic Settings for Data Factory $df_name in resource group \`${resource_group}\`" \
            --arg details "$err_msg" \
            --arg severity "4" \
            --arg nextStep "Enable diagnostics and configure Log Analytics for Data Factory \`$df_name\` in resource group \`${resource_group}\`" \
            --arg expected "Diagnostic settings should be enabled for Data Factory \`$df_name\` in resource group \`${resource_group}\`" \
            --arg resource_url "$df_url" \
            --arg reproduce_hint "az monitor diagnostic-settings list --resource \"$df_id\"" \
            --arg actual "Diagnostic settings not enabled for Data Factory \`$df_name\` in resource group \`${resource_group}\`" \
            '.error_trends += [{
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

    # Count how many PipelineRuns and ActivityRuns logs are enabled
    enabled_pipeline_runs_count=$(echo "$diagnostics" | jq '[.[0].logs[] | select(.category == "PipelineRuns" and .enabled == true)] | length')
    enabled_activity_runs_count=$(echo "$diagnostics" | jq '[.[0].logs[] | select(.category == "ActivityRuns" and .enabled == true)] | length')
    # If PipelineRuns logging is not enabled, report failure
    if [[ "$enabled_pipeline_runs_count" -eq 0 ]]; then
        error_trends_json=$(echo "$error_trends_json" | jq \
            --arg title "PipelineRuns Logging Disabled in Data Factory \`$df_name\` in resource group \`${resource_group}\`" \
            --arg details $diagnostics \
            --arg severity "4" \
            --arg nextStep "Enable 'PipelineRuns' logging in diagnostic settings of Data Factory in in resource group \`${resource_group}\`" \
            --arg expected "PipelineRuns logging should be enabled for Data Factory \`$df_name\` in resource group \`${resource_group}\`" \
            --arg reproduce_hint "az monitor diagnostic-settings list --resource \"$df_id\" -o json | jq '[.[0].logs[] | select(.category == \"PipelineRuns\" and .enabled == true)]'" \
            --arg resource_url $df_url \
            --arg actual "PipelineRuns logging not enabled for Data Factory \`$df_name\` in resource group \`${resource_group}\`" \
            '.error_trends += [{
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

    # Optional: Warn if ActivityRuns is not enabled
    if [[ "$enabled_activity_runs_count" -eq 0 ]]; then
        error_trends_json=$(echo "$error_trends_json" | jq \
            --arg title "ActivityRuns Logging Disabled in Data Factory \`$df_name\` in resource group \`${resource_group}\`" \
            --arg details $diagnostics \
            --arg severity "4" \
            --arg nextStep "Enable 'ActivityRuns' logging in diagnostic settings of Data Factory in resource group \`${resource_group}\`" \
            --arg expected "ActivityRuns logging should be enabled for Data Factory \`$df_name\` in resource group \`${resource_group}\`" \
            --arg reproduce_hint "az monitor diagnostic-settings list --resource \"$df_id\" -o json | jq '[.[0].logs[] | select(.category == \"ActivityRuns\" and .enabled == true)]'" \
            --arg resource_url $df_url \
            --arg actual "ActivityRuns logging not enabled for Data Factory \`$df_name\` in resource group \`${resource_group}\`" \
            '.error_trends += [{
                "title": $title,
                "details": $details,
                "next_step": $nextStep,
                "actual": $actual,
                "expected": $expected,
                "severity": ($severity | tonumber),
                "resource_url": $resource_url
            }]')
    fi

    if [[ -z "$workspace_id" || "$workspace_id" == "null" ]]; then
        error_trends_json=$(echo "$error_trends_json" | jq \
            --arg title "No Log Analytics Workspace for \`$df_name\` in resource group \`${resource_group}\`" \
            --arg details "Diagnostics are configured but no workspace is defined." \
            --arg severity "3" \
            --arg nextStep "Add Log Analytics workspace to diagnostics for Data Factory \`$df_name\` in resource group \`${resource_group}\`" \
            --arg expected "Log Analytics workspace should be configured for Data Factory \`$df_name\` in resource group \`${resource_group}\`" \
            --arg resource_url $df_url \
            --arg reproduce_hint "az monitor diagnostic-settings list --resource \"$df_id\" -o json | jq '[.[0].logs[] | select(.category == \"LogAnalytics\")]'" \
            --arg actual "Log Analytics workspace not configured for Data Factory \`$df_name\` in resource group \`${resource_group}\`" \
            '.error_trends += [{
                "title": $title,
                "details": $details,
                "next_step": $nextStep,
                "severity": ($severity | tonumber),
                "actual": $actual,
                "resource_url": $resource_url,
                "reproduce_hint": $reproduce_hint,
                "expected": $expected
            }]')
        continue
    fi

    # Get customer ID (GUID) for the workspace
    if ! workspace_guid=$(az monitor log-analytics workspace show --ids "$workspace_id" --query "customerId" -o tsv 2>guid_err.log); then
        err_msg=$(cat guid_err.log)
        rm -f guid_err.log

        error_trends_json=$(echo "$error_trends_json" | jq \
            --arg title "Failed to Get Workspace GUID for \`$df_name\` in resource group \`${resource_group}\`" \
            --arg details "$err_msg" \
            --arg severity "4" \
            --arg nextStep "Verify access to the workspace in resource group \`${resource_group}\`" \
            --arg resource_url "$df_url" \
            --arg expected "Workspace GUID should be available for Data Factory \`$df_name\` in resource group \`${resource_group}\`" \
            --arg reproduce_hint "az monitor log-analytics workspace show --ids \"$workspace_id\" --query customerId -o tsv" \
            --arg actual "Workspace GUID not available for Data Factory \`$df_name\` in resource group \`${resource_group}\`" \
            '.error_trends += [{
                "title": $title,
                "details": $details,
                "next_step": $nextStep,
                "severity": ($severity | tonumber),
                "actual": $actual,
                "resource_url": $resource_url,
                "reproduce_hint": $reproduce_hint,
                "expected": $expected
            }]')
        continue
    fi
    rm -f guid_err.log

    # KQL Query to get failed pipeline runs
    kql_query=$(cat <<EOF
AzureDiagnostics
| where ResourceProvider == "MICROSOFT.DATAFACTORY"
| where Category == "PipelineRuns"
| where status_s == "Failed"
| where TimeGenerated > ago($LOOKBACK_PERIOD)
| where Resource =~ "$df_name"
| extend MsgPrefix = substring(Message, 0, 100)
| summarize FailureCount = count(), LastSeen = max(TimeGenerated), Messages = make_list(Message, 2), RunId = make_list(runId_g, 1) by MsgPrefix, pipelineName_s, ResourceId
| sort by FailureCount desc
EOF
)

    echo "Querying failed pipeline runs for $df_name..."
    if ! error_trends=$(az monitor log-analytics query \
        --workspace "$workspace_guid" \
        --analytics-query "$kql_query" \
        --subscription "$subscription_id" \
        --output json 2>pipeline_query_err.log); then
        err_msg=$(cat pipeline_query_err.log)
        rm -f pipeline_query_err.log
        
        error_trends_json=$(echo "$error_trends_json" | jq \
            --arg title "Log Analytics Query Failed for \`$df_name\` in resource group \`${resource_group}\`" \
            --arg details "$err_msg" \
            --arg severity "2" \
            --arg nextStep "Verify workspace permissions or check if diagnostics have been sending data." \
            --arg resource_url "$df_url" \
            --arg expected "Log Analytics query should be successful for Data Factory \`$df_name\` in resource group \`${resource_group}\`" \
            --arg reproduce_hint "az monitor log-analytics query --workspace \"$workspace_guid\" --analytics-query '$kql_query' --subscription \"$subscription_id\" --output json" \
            --arg actual "Log Analytics query failed for Data Factory \`$df_name\` in resource group \`${resource_group}\`" \
            '.error_trends += [{
                "title": $title,
                "details": $details,
                "next_step": $nextStep,
                "severity": ($severity | tonumber),
                "actual": $actual,
                "resource_url": $resource_url,
                "reproduce_hint": $reproduce_hint,
                "expected": $expected
            }]')
        continue
    fi
    rm -f pipeline_query_err.log

    if ! echo "${error_trends}" | jq empty 2>/dev/null; then
        echo "Error: Invalid JSON in error_trends"
        continue
    fi
    
    while read -r pipeline; do
        pipeline_name=$(echo "$pipeline" | jq -r '.pipelineName_s')
        message=$(echo "$pipeline" | jq -r '.Messages | fromjson[0]')
        run_id=$(echo "$pipeline" | jq -r '.RunId | fromjson[0]')
        
        error_trends_json=$(echo "$error_trends_json" | jq \
            --arg title "Common Error in Data Factory Pipeline \`$pipeline_name\` in Data Factory \`$df_name\` in resource group \`${resource_group}\`" \
            --arg details "$pipeline" \
            --arg severity "3" \
            --arg nextStep "Inspect the pipeline run logs in Azure Data Factory portal in resource group \`${resource_group}\`" \
            --arg name "$pipeline_name" \
            --arg expected "Data Factory Pipeline \`$pipeline_name\` should not have frequent errors in resource group \`${resource_group}\`" \
            --arg actual "Data Factory Pipeline \`$pipeline_name\` has frequent errors in resource group \`${resource_group}\`" \
            --arg resource_url "$df_url" \
            --arg reproduce_hint "az monitor log-analytics query --workspace \"$workspace_guid\" --analytics-query '$kql_query' --subscription \"$subscription_id\" --output json" \
            --arg run_id "$run_id" \
            '.error_trends += [{
                "title": $title,
                "details": $details,
                "next_step": $nextStep,
                "actual": $actual,
                "severity": ($severity | tonumber),
                "name": $name,
                "resource_url": $resource_url,
                "reproduce_hint": $reproduce_hint,
                "expected": $expected,
                "run_id": $run_id
            }]')
    done < <(echo "$error_trends" | jq -c '.[]')
done

# Write output to file
echo "Final JSON contents:"
echo "$error_trends_json" | jq
echo "$error_trends_json" > "$output_file"
echo "Failed pipeline check completed. Results saved to $output_file"
