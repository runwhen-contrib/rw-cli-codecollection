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
: "${LOOKBACK_PERIOD:=7d}"

subscription_id="$AZURE_RESOURCE_SUBSCRIPTION_ID"
resource_group="$AZURE_RESOURCE_GROUP"
output_file="failed_pipelines.json"
output_json='{"failed_pipelines": [], "script_errors": []}'

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
        echo "$output_json" > "$output_file"
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
    echo "$output_json" > "$output_file"
    exit 1
fi

echo "Checking Data Factories and retrieving failed pipeline runs..."
echo "Resource Group: $resource_group"
echo "Subscription ID: $subscription_id"

# Allow preview extensions to be installed
az config set extension.dynamic_install_allow_preview=true

# Ensure log-analytics extension is available
if ! az extension show --name log-analytics &>/dev/null; then
    echo "Installing log-analytics extension..."
    az extension add -n log-analytics
fi

# Get all Data Factories in the resource group
raw_output=$(az datafactory list -g "$resource_group" --subscription "$subscription_id" -o json 2>az_datafactory_err.log || true)
if ! validate_json "$raw_output"; then
    err_msg=$(cat az_datafactory_err.log)
    rm -f az_datafactory_err.log
    output_json=$(echo "$output_json" | jq \
        --arg title "Invalid JSON from datafactory list" \
        --arg details "Error: $err_msg | Raw output: $raw_output" \
        --arg severity "4" \
        --arg nextStep "Check Azure CLI output and permissions." \
        --arg expected "Valid JSON output from datafactory list" \
        --arg actual "Invalid JSON output from datafactory list" \
        '.script_errors += [{
            "title": $title,
            "details": $details,
            "next_step": $nextStep,
            "expected": $expected,
            "actual": $actual,
            "severity": ($severity | tonumber)
        }]')
    raw_output="[]"
fi
rm -f az_datafactory_err.log

if [[ -z "$raw_output" || "$raw_output" == "[]" ]]; then
    echo "No Data Factories found in resource group $resource_group"
    echo "$output_json" > "$output_file"
    exit 0
fi

for row in $(echo "$raw_output" | jq -c '.[]'); do
    df_name=$(echo "$row" | jq -r '.name')
    df_id=$(echo "$row" | jq -r '.id')
    df_rg=$(echo "$row" | jq -r '.resourceGroup')
    df_url="https://adf.azure.com/en/monitoring/pipelineruns?factory=${df_id}"

    echo "Processing Data Factory: $df_name"

    # Get linked services with robust error handling
    linked_services=$(az datafactory linked-service list --factory-name "$df_name" --resource-group "$df_rg" --subscription "$subscription_id" -o json 2>az_linked_services_err.log) || linked_services="[]"
    if ! validate_json "$linked_services"; then
        err_msg=$(cat az_linked_services_err.log)
        rm -f az_linked_services_err.log
        output_json=$(echo "$output_json" | jq \
            --arg title "Invalid JSON from linked services for $df_name" \
            --arg details "Error: $err_msg | Raw output: $linked_services" \
            --arg severity "4" \
            --arg nextStep "Check Azure CLI output and permissions." \
            --arg expected "Valid JSON output from linked services for $df_name" \
            --arg actual "Invalid JSON output from linked services for $df_name" \
            '.script_errors += [{
                "title": $title,
                "details": $details,
                "next_step": $nextStep,
                "expected": $expected,
                "actual": $actual,
                "severity": ($severity | tonumber)
            }]')
        linked_services="[]"
    fi
    rm -f az_linked_services_err.log
    if [[ -z "$linked_services" || "$linked_services" == "[]" ]]; then
        linked_services="[]"
    else
        linked_services=$(echo "$linked_services" | jq -c --arg df_id "$df_id" 'map(. + {url: ("https://adf.azure.com/en/management/datalinkedservices?factory=" + $df_id)})')
    fi
    
    # Get diagnostic settings
    diagnostics=$(az monitor diagnostic-settings list --resource "$df_id" -o json 2>diag_err.log || true)
    
    if [[ -z "$diagnostics" || "$diagnostics" == "[]" ]]; then
        err_msg=$(cat diag_err.log)
        rm -f diag_err.log

        output_json=$(echo "$output_json" | jq \
            --arg title "No Diagnostic Settings for Data Factory \`$df_name\` in resource group \`${resource_group}\`" \
            --arg details "$err_msg" \
            --arg severity "4" \
            --arg nextStep "Enable diagnostics and configure Log Analytics for Data Factory \`$df_name\` in resource group \`${resource_group}\`" \
            --arg expected "Diagnostic settings should be enabled for Data Factory \`$df_name\` in resource group \`${resource_group}\`" \
            --arg actual "Diagnostic settings not enabled for Data Factory \`$df_name\` in resource group \`${resource_group}\`" \
            --arg resource_url "$df_url" \
            --arg reproduce_hint "az monitor diagnostic-settings list --resource \"$df_id\"" \
            '.script_errors += [{
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
        output_json=$(echo "$output_json" | jq \
            --arg title "PipelineRuns Logging Disabled in Data Factory \`$df_name\` in resource group \`${resource_group}\`" \
            --arg details "$diagnostics" \
            --arg severity "3" \
            --arg nextStep "Enable 'PipelineRuns' logging in diagnostic settings of Data Factory \`$df_name\` in resource group \`${resource_group}\`" \
            --arg expected "PipelineRuns logging should be enabled for Data Factory \`$df_name\` in resource group \`${resource_group}\`" \
            --arg actual "PipelineRuns logging is disabled for Data Factory \`$df_name\` in resource group \`${resource_group}\`" \
            --arg resource_url "$df_url" \
            --arg reproduce_hint "az monitor diagnostic-settings list --resource \"$df_id\"" \
            '.script_errors += [{
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
        output_json=$(echo "$output_json" | jq \
            --arg title "ActivityRuns Logging Disabled in Data Factory \`$df_name\` in resource group \`${resource_group}\`" \
            --arg details "You may miss detailed activity-level diagnostics without 'ActivityRuns' logging." \
            --arg severity "4" \
            --arg nextStep "Consider enabling 'ActivityRuns' logging in diagnostic settings of Data Factory \`$df_name\` in resource group \`${resource_group}\`" \
            --arg expected "ActivityRuns logging should be enabled for Data Factory \`$df_name\` in resource group \`${resource_group}\`" \
            --arg actual "ActivityRuns logging is disabled for Data Factory \`$df_name\` in resource group \`${resource_group}\`" \
            --arg resource_url "$df_url" \
            --arg reproduce_hint "az monitor diagnostic-settings list --resource \"$df_id\"" \
            '.script_errors += [{
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
        output_json=$(echo "$output_json" | jq \
            --arg title "No Log Analytics Workspace for Data Factory \`$df_name\` in resource group \`${resource_group}\`" \
            --arg details "Diagnostics are configured but no workspace is defined." \
            --arg severity "4" \
            --arg nextStep "Add Log Analytics workspace to diagnostics for Data Factory \`$df_name\` in resource group \`${resource_group}\`" \
            --arg expected "Log Analytics workspace should be configured for Data Factory \`$df_name\` in resource group \`${resource_group}\`" \
            --arg actual "No Log Analytics workspace configured for Data Factory \`$df_name\` in resource group \`${resource_group}\`" \
            --arg resource_url "$df_url" \
            --arg reproduce_hint "az monitor diagnostic-settings list --resource \"$df_id\"" \
            '.script_errors += [{
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

        output_json=$(echo "$output_json" | jq \
            --arg title "Failed to Get Workspace GUID for Data Factory \`$df_name\` in resource group \`${resource_group}\`" \
            --arg details "$err_msg" \
            --arg severity "4" \
            --arg nextStep "Verify access to the workspace or check if the workspace ID is valid." \
            --arg expected "Should be able to get workspace GUID for Data Factory \`$df_name\` in resource group \`${resource_group}\`" \
            --arg actual "Failed to get workspace GUID for Data Factory \`$df_name\` in resource group \`${resource_group}\`" \
            --arg resource_url "$df_url" \
            --arg reproduce_hint "az monitor log-analytics workspace show --ids \"$workspace_id\" --query \"customerId\" -o tsv" \
            '.script_errors += [{
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
    # Example: Log Analytics Query Failure (script error)
    if ! failed_pipelines=$(az monitor log-analytics query \
        --workspace "$workspace_guid" \
        --analytics-query "$kql_query" \
        --subscription "$subscription_id" \
        --output json 2>pipeline_query_err.log); then
        err_msg=$(cat pipeline_query_err.log)
        rm -f pipeline_query_err.log
        
        output_json=$(echo "$output_json" | jq \
            --arg title "Log Analytics Query Failed for Data Factory \`$df_name\` in resource group \`${resource_group}\`" \
            --arg details "$err_msg" \
            --arg severity "3" \
            --arg nextStep "Verify workspace permissions or check if diagnostics have been sending data." \
            --arg expected "Log Analytics query should be successful for Data Factory \`$df_name\` in resource group \`${resource_group}\`" \
            --arg actual "Log Analytics query failed for Data Factory \`$df_name\` in resource group \`${resource_group}\`" \
            --arg resource_url "$df_url" \
            --arg reproduce_hint "az monitor log-analytics query --workspace \"$workspace_guid\" --analytics-query '$kql_query' --subscription \"$subscription_id\" --output json" \
            '.script_errors += [{
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

    # Check if output is .tables[0].rows or a flat array
    if echo "$failed_pipelines" | jq -e '.tables[0].rows' >/dev/null 2>&1; then
        row_count=$(echo "$failed_pipelines" | jq '.tables[0].rows | length')
        if [[ "$row_count" -eq 0 ]]; then
            echo "No failed pipeline runs found for $df_name"
            continue
        fi
        rows=$(echo "$failed_pipelines" | jq -c '
          .tables[0].rows[] as $row |
          {
            pipelineName_s: $row[0],
            Message: $row[1],
            runId_g: $row[2]
          }
        ')
    elif echo "$failed_pipelines" | jq -e '.[0].pipelineName_s' >/dev/null 2>&1; then
        row_count=$(echo "$failed_pipelines" | jq 'length')
        if [[ "$row_count" -eq 0 ]]; then
            echo "No failed pipeline runs found for $df_name"
            continue
        fi
        rows=$(echo "$failed_pipelines" | jq -c '.[] | { pipelineName_s, Message, runId_g }')
    else
        echo "No failed pipeline rows or invalid JSON returned for $df_name"
        continue
    fi

    # Example: Actual Failed Pipeline Run
    while IFS= read -r pipeline; do
        pipeline_name=$(echo "$pipeline" | jq -r '.pipelineName_s')
        message=$(echo "$pipeline" | jq -r '.Message')
        run_id=$(echo "$pipeline" | jq -r '.runId_g')
        
        output_json=$(echo "$output_json" | jq \
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
    done <<< "$rows"
done

# Write output to file
echo "Final JSON contents:"
echo "$output_json" | jq
echo "$output_json" > "$output_file"
echo "Failed pipeline check completed. Results saved to $output_file"
