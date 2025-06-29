#!/bin/bash
set -euo pipefail

# -----------------------------------------------------------------------------
# REQUIRED ENV VARS:
#   AZURE_RESOURCE_GROUP
#   AZURE_RESOURCE_SUBSCRIPTION_ID
#   LOOKBACK_PERIOD
# -----------------------------------------------------------------------------

: "${AZURE_RESOURCE_GROUP:?Must set AZURE_RESOURCE_GROUP}"
: "${AZURE_RESOURCE_SUBSCRIPTION_ID:?Must set AZURE_RESOURCE_SUBSCRIPTION_ID}"
: "${LOOKBACK_PERIOD:?Must set LOOKBACK_PERIOD}"

subscription_id="$AZURE_RESOURCE_SUBSCRIPTION_ID"
resource_group="$AZURE_RESOURCE_GROUP"
output_file="failed_pipelines.json"
failed_pipelines_json='{"failed_pipelines": []}'

# Function to validate JSON
validate_json() {
    local json_data="$1"
    if [[ -z "$json_data" ]]; then
        echo "Empty JSON data" >&2
        return 1
    fi
    if ! echo "$json_data" | jq empty 2>/dev/null; then
        echo "Invalid JSON format" >&2
        return 1
    fi
    return 0
}

# Function to safely extract JSON field
safe_jq() {
    local json_data="$1"
    local filter="$2"
    local default="${3:-}"
    
    if validate_json "$json_data"; then
        echo "$json_data" | jq -r "$filter" 2>/dev/null || echo "$default"
    else
        echo "$default"
    fi
}

# Get or set subscription ID
if [[ -z "${AZURE_RESOURCE_SUBSCRIPTION_ID:-}" ]]; then
    subscription=$(az account show --query "id" -o tsv 2>/dev/null || echo "")
    if [[ -z "$subscription" ]]; then
        echo "ERROR: Could not determine current subscription ID and AZURE_RESOURCE_SUBSCRIPTION_ID is not set."
        echo "$failed_pipelines_json" > "$output_file"
        exit 1
    fi
    echo "AZURE_RESOURCE_SUBSCRIPTION_ID is not set. Using current subscription ID: $subscription"
else
    subscription="$AZURE_RESOURCE_SUBSCRIPTION_ID"
    echo "Using specified subscription ID: $subscription"
fi

# Set the subscription to the determined ID
echo "Switching to subscription ID: $subscription"
if ! az account set --subscription "$subscription" 2>/dev/null; then
    echo "ERROR: Failed to set subscription to $subscription"
    echo "$failed_pipelines_json" > "$output_file"
    exit 1
fi

echo "Checking Data Factories and retrieving failed pipeline runs..."
echo "Resource Group: $resource_group"
echo "Subscription ID: $subscription_id"

# Ensure log-analytics extension is available
if ! az extension show --name log-analytics &>/dev/null; then
    echo "Installing log-analytics extension..."
    az extension add -n log-analytics
fi

# Get all Data Factories in the resource group
datafactories=$(az datafactory list -g "$resource_group" --subscription "$subscription_id" -o json)

if [[ -z "$datafactories" || "$datafactories" == "[]" ]]; then
    echo "No Data Factories found in resource group $resource_group"
    echo "$failed_pipelines_json" > "$output_file"
    exit 0
fi

for row in $(echo "$datafactories" | jq -c '.[]'); do
    df_name=$(echo "$row" | jq -r '.name')
    df_id=$(echo "$row" | jq -r '.id')
    df_rg=$(echo "$row" | jq -r '.resourceGroup')
    df_url="https://adf.azure.com/en/monitoring/pipelineruns?factory=${df_id}"

    echo "Processing Data Factory: $df_name"

    # Get linked services
    echo "Getting linked services for $df_name..."
    linked_services=$(az datafactory linked-service list --factory-name "$df_name" --resource-group "$df_rg" --subscription "$subscription_id" -o json)
    linked_services=$(echo "$linked_services" | jq -c --arg df_id "$df_id" 'map(. + {url: ("https://adf.azure.com/en/management/datalinkedservices?factory=" + $df_id)})')
    
    # Get diagnostic settings
    diagnostics=$(az monitor diagnostic-settings list --resource "$df_id" -o json 2>diag_err.log || true)
    
    if [[ -z "$diagnostics" || "$diagnostics" == "[]" ]]; then
        err_msg=$(cat diag_err.log)
        rm -f diag_err.log

        failed_pipelines_json=$(echo "$failed_pipelines_json" | jq \
            --arg title "No Diagnostic Settings for Data Factory \`$df_name\` in resource group \`${resource_group}\`" \
            --arg details "$err_msg" \
            --arg severity "4" \
            --arg nextStep "Enable diagnostics and configure Log Analytics for Data Factory \`$df_name\` in resource group \`${resource_group}\`" \
            --arg expected "Diagnostic settings should be enabled for Data Factory \`$df_name\` in resource group \`${resource_group}\`" \
            --arg actual "Diagnostic settings not enabled for Data Factory \`$df_name\` in resource group \`${resource_group}\`" \
            --arg resource_url "$df_url" \
            --arg reproduce_hint "az monitor diagnostic-settings list --resource \"$df_id\"" \
            '.failed_pipelines += [{
                "title": $title,
                "details": $details,
                "next_step": $nextStep,
                "expected": $expected,
                "actual": $actual,
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
        failed_pipelines_json=$(echo "$failed_pipelines_json" | jq \
            --arg title "PipelineRuns Logging Disabled in Data Factory \`$df_name\` in resource group \`${resource_group}\`" \
            --arg details "$diagnostics" \
            --arg severity "3" \
            --arg nextStep "Enable 'PipelineRuns' logging in diagnostic settings of Data Factory \`$df_name\` in resource group \`${resource_group}\`" \
            --arg expected "PipelineRuns logging should be enabled for Data Factory \`$df_name\` in resource group \`${resource_group}\`" \
            --arg actual "PipelineRuns logging is disabled for Data Factory \`$df_name\` in resource group \`${resource_group}\`" \
            --arg resource_url "$df_url" \
            --arg reproduce_hint "az monitor diagnostic-settings list --resource \"$df_id\"" \
            '.failed_pipelines += [{
                "title": $title,
                "details": $details,
                "next_step": $nextStep,
                "expected": $expected,
                "actual": $actual,
                "severity": ($severity | tonumber),
                "resource_url": $resource_url,
                "reproduce_hint": $reproduce_hint
            }]')
        continue
    fi

    # Optional: Warn if ActivityRuns is not enabled
    if [[ "$enabled_activity_runs_count" -eq 0 ]]; then
        failed_pipelines_json=$(echo "$failed_pipelines_json" | jq \
            --arg title "ActivityRuns Logging Disabled in Data Factory \`$df_name\` in resource group \`${resource_group}\`" \
            --arg details "You may miss detailed activity-level diagnostics without 'ActivityRuns' logging." \
            --arg severity "4" \
            --arg nextStep "Consider enabling 'ActivityRuns' logging in diagnostic settings of Data Factory \`$df_name\` in resource group \`${resource_group}\`" \
            --arg expected "ActivityRuns logging should be enabled for Data Factory \`$df_name\` in resource group \`${resource_group}\`" \
            --arg actual "ActivityRuns logging is disabled for Data Factory \`$df_name\` in resource group \`${resource_group}\`" \
            --arg resource_url "$df_url" \
            --arg reproduce_hint "az monitor diagnostic-settings list --resource \"$df_id\"" \
            '.failed_pipelines += [{
                "title": $title,
                "details": $details,
                "next_step": $nextStep,
                "expected": $expected,
                "actual": $actual,
                "severity": ($severity | tonumber),
                "resource_url": $resource_url,
                "reproduce_hint": $reproduce_hint
            }]')
    fi

    if [[ -z "$workspace_id" || "$workspace_id" == "null" ]]; then
        failed_pipelines_json=$(echo "$failed_pipelines_json" | jq \
            --arg title "No Log Analytics Workspace for Data Factory \`$df_name\` in resource group \`${resource_group}\`" \
            --arg details "Diagnostics are configured but no workspace is defined." \
            --arg severity "4" \
            --arg nextStep "Add Log Analytics workspace to diagnostics for Data Factory \`$df_name\` in resource group \`${resource_group}\`" \
            --arg expected "Log Analytics workspace should be configured for Data Factory \`$df_name\` in resource group \`${resource_group}\`" \
            --arg actual "No Log Analytics workspace configured for Data Factory \`$df_name\` in resource group \`${resource_group}\`" \
            --arg resource_url "$df_url" \
            --arg reproduce_hint "az monitor diagnostic-settings list --resource \"$df_id\"" \
            '.failed_pipelines += [{
                "title": $title,
                "details": $details,
                "next_step": $nextStep,
                "expected": $expected,
                "actual": $actual,
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

        failed_pipelines_json=$(echo "$failed_pipelines_json" | jq \
            --arg title "Failed to Get Workspace GUID for Data Factory \`$df_name\` in resource group \`${resource_group}\`" \
            --arg details "$err_msg" \
            --arg severity "4" \
            --arg nextStep "Verify access to the workspace or check if the workspace ID is valid." \
            --arg expected "Should be able to get workspace GUID for Data Factory \`$df_name\` in resource group \`${resource_group}\`" \
            --arg actual "Failed to get workspace GUID for Data Factory \`$df_name\` in resource group \`${resource_group}\`" \
            --arg resource_url "$df_url" \
            --arg reproduce_hint "az monitor log-analytics workspace show --ids \"$workspace_id\" --query \"customerId\" -o tsv" \
            '.failed_pipelines += [{
                "title": $title,
                "details": $details,
                "next_step": $nextStep,
                "expected": $expected,
                "actual": $actual,
                "severity": ($severity | tonumber),
                "resource_url": $resource_url,
                "reproduce_hint": $reproduce_hint
            }]')
        continue
    fi
    rm -f guid_err.log

    # KQL Query
    kql_query=$(cat <<EOF
AzureDiagnostics
| where ResourceProvider == "MICROSOFT.DATAFACTORY"
| where Category == "PipelineRuns"
| where status_s == "Failed"
| where Resource =~ "$df_name"
| where TimeGenerated > ago($LOOKBACK_PERIOD)
| summarize by pipelineName_s, Message, runId_g
EOF
)
    echo "Querying failed pipeline runs for $df_name..."
    if ! failed_pipelines=$(az monitor log-analytics query \
        --workspace "$workspace_guid" \
        --analytics-query "$kql_query" \
        --subscription "$subscription_id" \
        --output json 2>pipeline_query_err.log); then
        err_msg=$(cat pipeline_query_err.log)
        rm -f pipeline_query_err.log

        failed_pipelines_json=$(echo "$failed_pipelines_json" | jq \
            --arg title "Log Analytics Query Failed for Data Factory \`$df_name\` in resource group \`${resource_group}\`" \
            --arg details "$err_msg" \
            --arg severity "3" \
            --arg nextStep "Verify workspace permissions or check if diagnostics have been sending data." \
            --arg expected "Log Analytics query should be successful for Data Factory \`$df_name\` in resource group \`${resource_group}\`" \
            --arg actual "Log Analytics query failed for Data Factory \`$df_name\` in resource group \`${resource_group}\`" \
            --arg resource_url "$df_url" \
            --arg reproduce_hint "az monitor log-analytics query --workspace \"$workspace_guid\" --analytics-query '$kql_query' --subscription \"$subscription_id\" --output json" \
            '.failed_pipelines += [{
                "title": $title,
                "details": $details,
                "next_step": $nextStep,
                "expected": $expected,
                "actual": $actual,
                "severity": ($severity | tonumber),
                "resource_url": $resource_url,
                "reproduce_hint": $reproduce_hint
            }]')
        continue
    fi
    rm -f pipeline_query_err.log

    # Parse failed pipeline results
    if ! echo "${failed_pipelines}" | jq empty 2>/dev/null; then
        echo "Error: Invalid JSON in failed_pipelines"
        continue
    fi
    while read -r pipeline; do
        pipeline_name=$(echo "$pipeline" | jq -r '.pipelineName_s')
        message=$(echo "$pipeline" | jq -r '.Messages')
        run_id=$(echo "$pipeline" | jq -r '.runId_g')
        
        failed_pipelines_json=$(echo "$failed_pipelines_json" | jq \
            --arg title "Failed Pipeline \`$pipeline_name\` in Data Factory \`$df_name\` in resource group \`${resource_group}\`" \
            --arg details "$pipeline" \
            --arg severity "3" \
            --arg nextStep "Inspect the pipeline run logs in Azure Data Factory portal in resource group \`${resource_group}\`" \
            --arg name "$pipeline_name" \
            --arg expected "Pipeline \`$pipeline_name\` should execute successfully in resource group \`${resource_group}\`" \
            --arg actual "Pipeline \`$pipeline_name\` has failed times with error in resource group \`${resource_group}\`" \
            --arg resource_url "$df_url" \
            --arg reproduce_hint "az monitor log-analytics query --workspace \"$workspace_guid\" --analytics-query '$kql_query' --subscription \"$subscription_id\" --output json" \
            --arg run_id "$run_id" \
            --argjson linked_services "$linked_services" \
            '.failed_pipelines += [{
                "title": $title,
                "details": $details,
                "next_step": $nextStep,
                "expected": $expected,
                "actual": $actual,
                "severity": ($severity | tonumber),
                "name": $name,
                "resource_url": $resource_url,
                "reproduce_hint": $reproduce_hint,
                "run_id": $run_id,
                "linked_services": $linked_services
            }]')
    done < <(echo "$failed_pipelines" | jq -c '.[]')
done

# Write output to file
echo "Final JSON contents:"
echo "$failed_pipelines_json" | jq
echo "$failed_pipelines_json" > "$output_file"
echo "Failed pipeline check completed. Results saved to $output_file"
