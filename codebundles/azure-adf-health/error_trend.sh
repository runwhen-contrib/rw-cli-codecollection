#!/bin/bash
set -euo pipefail

# -----------------------------------------------------------------------------
# REQUIRED ENV VARS:
#   AZURE_RESOURCE_GROUP
#   AZURE_RESOURCE_SUBSCRIPTION_ID
#   LOOKBACK_PERIOD (optional, default: 7d)
# -----------------------------------------------------------------------------

: "${AZURE_RESOURCE_GROUP:?Must set AZURE_RESOURCE_GROUP}"
: "${AZURE_RESOURCE_SUBSCRIPTION_ID:?Must set AZURE_RESOURCE_SUBSCRIPTION_ID}"
: "${LOOKBACK_PERIOD:=7d}"

subscription_id="$AZURE_RESOURCE_SUBSCRIPTION_ID"
resource_group="$AZURE_RESOURCE_GROUP"
output_file="error_trend.json"
error_trends_json='{"error_trends": [], "script_errors": []}'

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
        echo "$error_trends_json" > "$output_file"
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
    echo "$error_trends_json" > "$output_file"
    exit 1
fi

echo "Checking Data Factories and retrieving failed pipeline runs..."
echo "Resource Group: $resource_group"
echo "Subscription ID: $subscription_id"

# Configure Azure CLI to explicitly allow or disallow preview extensions
echo "Configuring Azure CLI extensions..."
if ! az config set extension.dynamic_install_allow_preview=true 2>/dev/null; then
    echo "WARNING: Could not configure Azure CLI extension settings"
fi

# Check and install datafactory extension if needed
echo "Checking for datafactory extension..."
if ! az extension show --name datafactory >/dev/null 2>&1; then
    echo "Installing datafactory extension..."
    if ! az extension add --name datafactory 2>/dev/null; then
        echo "ERROR: Failed to install datafactory extension."
        echo "$error_trends_json" > "$output_file"
        exit 1
    fi
fi

# Check and install log-analytics extension if needed
if ! az extension show --name log-analytics >/dev/null 2>&1; then
    echo "Installing log-analytics extension..."
    if ! az extension add --name log-analytics 2>/dev/null; then
        echo "ERROR: Failed to install log-analytics extension."
        error_trends_json=$(echo "$error_trends_json" | jq \
            --arg title "Failed to install log-analytics extension" \
            --arg details "Could not install log-analytics extension via az CLI" \
            --arg severity "4" \
            --arg nextStep "Install log-analytics extension manually" \
            --arg expected "log-analytics extension should be installed" \
            --arg actual "log-analytics extension not installed" \
            '.script_errors += [{
                "title": $title,
                "details": $details,
                "next_step": $nextStep,
                "expected": $expected,
                "actual": $actual,
                "severity": ($severity | tonumber)
            }]')
        echo "$error_trends_json" | jq .
        echo "$error_trends_json" > "$output_file"
        exit 1
    fi
fi

# Get all Data Factories in the resource group
echo "Fetching Data Factories..."
if ! datafactories=$(az datafactory list -g "$resource_group" --subscription "$subscription_id" -o json 2>/dev/null); then
    echo "ERROR: Failed to list Data Factories in resource group $resource_group"
    echo "$error_trends_json" > "$output_file"
    exit 1
fi

if ! validate_json "$datafactories"; then
    echo "ERROR: Invalid JSON response from Data Factory list command"
    echo "$error_trends_json" > "$output_file"
    exit 1
fi

if [[ "$datafactories" == "[]" ]] || [[ -z "$datafactories" ]]; then
    echo "No Data Factories found in resource group $resource_group"
    echo "$error_trends_json" > "$output_file"
    exit 0
fi

while IFS= read -r row; do
    if [[ -z "$row" ]] || ! validate_json "$row"; then
        echo "Skipping invalid Data Factory entry"
        continue
    fi
    
    df_name=$(safe_jq "$row" '.name' "unknown")
    df_id=$(safe_jq "$row" '.id' "")
    df_rg=$(safe_jq "$row" '.resourceGroup' "$resource_group")
    df_url="https://adf.azure.com/en/monitoring/pipelineruns?factory=${df_id}"

    if [[ -z "$df_id" ]] || [[ "$df_name" == "unknown" ]]; then
        echo "Skipping Data Factory with missing required fields"
        continue
    fi

    echo "Processing Data Factory: $df_name"

    # Get diagnostic settings with better error handling
    diagnostics=""
    if ! diagnostics=$(az monitor diagnostic-settings list --resource "$df_id" -o json 2>diag_err.log); then
        err_msg="Failed to get diagnostic settings"
        if [[ -f diag_err.log ]]; then
            err_msg=$(cat diag_err.log 2>/dev/null || echo "$err_msg")
        fi
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
            '.script_errors += [{
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

    if ! validate_json "$diagnostics" || [[ "$diagnostics" == "[]" ]]; then
        error_trends_json=$(echo "$error_trends_json" | jq \
            --arg title "No Diagnostic Settings for Data Factory $df_name in resource group \`${resource_group}\`" \
            --arg details "No diagnostic settings configured or invalid response" \
            --arg severity "4" \
            --arg nextStep "Enable diagnostics and configure Log Analytics for Data Factory \`$df_name\` in resource group \`${resource_group}\`" \
            --arg expected "Diagnostic settings should be enabled for Data Factory \`$df_name\` in resource group \`${resource_group}\`" \
            --arg resource_url "$df_url" \
            --arg reproduce_hint "az monitor diagnostic-settings list --resource \"$df_id\"" \
            --arg actual "Diagnostic settings not enabled for Data Factory \`$df_name\` in resource group \`${resource_group}\`" \
            '.script_errors += [{
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

    # Extract Log Analytics workspace ID
    workspace_id=$(safe_jq "$diagnostics" '.[0].workspaceId // empty' "")

    # Count how many PipelineRuns and ActivityRuns logs are enabled
    enabled_pipeline_runs_count=$(safe_jq "$diagnostics" '[.[0].logs[] | select(.category == "PipelineRuns" and .enabled == true)] | length' "0")
    enabled_activity_runs_count=$(safe_jq "$diagnostics" '[.[0].logs[] | select(.category == "ActivityRuns" and .enabled == true)] | length' "0")
    
    # If PipelineRuns logging is not enabled, report failure
    if [[ "$enabled_pipeline_runs_count" -eq 0 ]]; then
        error_trends_json=$(echo "$error_trends_json" | jq \
            --arg title "PipelineRuns Logging Disabled in Data Factory \`$df_name\` in resource group \`${resource_group}\`" \
            --arg details "$diagnostics" \
            --arg severity "4" \
            --arg nextStep "Enable 'PipelineRuns' logging in diagnostic settings of Data Factory in in resource group \`${resource_group}\`" \
            --arg expected "PipelineRuns logging should be enabled for Data Factory \`$df_name\` in resource group \`${resource_group}\`" \
            --arg reproduce_hint "az monitor diagnostic-settings list --resource \"$df_id\" -o json | jq '[.[0].logs[] | select(.category == \"PipelineRuns\" and .enabled == true)]'" \
            --arg resource_url "$df_url" \
            --arg actual "PipelineRuns logging not enabled for Data Factory \`$df_name\` in resource group \`${resource_group}\`" \
            '.script_errors += [{
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
            --arg details "$diagnostics" \
            --arg severity "4" \
            --arg nextStep "Enable 'ActivityRuns' logging in diagnostic settings of Data Factory in resource group \`${resource_group}\`" \
            --arg expected "ActivityRuns logging should be enabled for Data Factory \`$df_name\` in resource group \`${resource_group}\`" \
            --arg reproduce_hint "az monitor diagnostic-settings list --resource \"$df_id\" -o json | jq '[.[0].logs[] | select(.category == \"ActivityRuns\" and .enabled == true)]'" \
            --arg resource_url "$df_url" \
            --arg actual "ActivityRuns logging not enabled for Data Factory \`$df_name\` in resource group \`${resource_group}\`" \
            '.script_errors += [{
                "title": $title,
                "details": $details,
                "next_step": $nextStep,
                "actual": $actual,
                "expected": $expected,
                "severity": ($severity | tonumber),
                "resource_url": $resource_url,
                "reproduce_hint": $reproduce_hint
            }]')
    fi

    if [[ -z "$workspace_id" ]] || [[ "$workspace_id" == "null" ]]; then
        error_trends_json=$(echo "$error_trends_json" | jq \
            --arg title "No Log Analytics Workspace for \`$df_name\` in resource group \`${resource_group}\`" \
            --arg details "Diagnostics are configured but no workspace is defined." \
            --arg severity "3" \
            --arg nextStep "Add Log Analytics workspace to diagnostics for Data Factory \`$df_name\` in resource group \`${resource_group}\`" \
            --arg expected "Log Analytics workspace should be configured for Data Factory \`$df_name\` in resource group \`${resource_group}\`" \
            --arg resource_url "$df_url" \
            --arg reproduce_hint "az monitor diagnostic-settings list --resource \"$df_id\" -o json | jq '[.[0].logs[] | select(.category == \"LogAnalytics\")]'" \
            --arg actual "Log Analytics workspace not configured for Data Factory \`$df_name\` in resource group \`${resource_group}\`" \
            '.script_errors += [{
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
    workspace_guid=""
    if ! workspace_guid=$(az monitor log-analytics workspace show --ids "$workspace_id" --query "customerId" -o tsv 2>guid_err.log); then
        err_msg="Failed to get workspace GUID"
        if [[ -f guid_err.log ]]; then
            err_msg=$(cat guid_err.log 2>/dev/null || echo "$err_msg")
        fi
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
            '.script_errors += [{
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

    if [[ -z "$workspace_guid" ]]; then
        error_trends_json=$(echo "$error_trends_json" | jq \
            --arg title "Empty workspace GUID for \`$df_name\` in resource group \`${resource_group}\`" \
            --arg details "Workspace GUID is empty or null" \
            --arg severity "4" \
            --arg nextStep "Verify workspace configuration" \
            --arg resource_url "$df_url" \
            --arg expected "Should have valid workspace GUID for Data Factory \`$df_name\` in resource group \`${resource_group}\`" \
            --arg reproduce_hint "az monitor log-analytics workspace show --ids \"$workspace_id\" --query customerId -o tsv" \
            --arg actual "Empty workspace GUID for Data Factory \`$df_name\` in resource group \`${resource_group}\`" \
            '.script_errors += [{
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
    error_trends=""
    if ! error_trends=$(az monitor log-analytics query \
        --workspace "$workspace_guid" \
        --analytics-query "$kql_query" \
        --subscription "$subscription_id" \
        --output json 2>pipeline_query_err.log); then
        err_msg="Log Analytics query failed"
        if [[ -f pipeline_query_err.log ]]; then
            err_msg=$(cat pipeline_query_err.log 2>/dev/null || echo "$err_msg")
        fi
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
            '.script_errors += [{
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

    if ! validate_json "$error_trends"; then
        echo "Warning: Invalid JSON in error_trends for $df_name, skipping..."
        continue
    fi
    
    # Process error trends if valid
    while IFS= read -r pipeline; do
        if [[ -z "$pipeline" ]] || ! validate_json "$pipeline"; then
            continue
        fi
        
        pipeline_name=$(safe_jq "$pipeline" '.pipelineName_s' "unknown")
        message=$(safe_jq "$pipeline" '.Messages | fromjson[0]' "No message available")
        run_id=$(safe_jq "$pipeline" '.RunId | fromjson[0]' "unknown")
        
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
    done < <(echo "$error_trends" | jq -c '.[]' 2>/dev/null || echo "")
done < <(echo "$datafactories" | jq -c '.[]' 2>/dev/null || echo "")

# Write output to file
echo "Final JSON contents:"
if validate_json "$error_trends_json"; then
    echo "$error_trends_json" | jq . 2>/dev/null || echo "$error_trends_json"
else
    echo "Warning: Final JSON is invalid, using fallback"
    error_trends_json='{"error_trends": [], "script_errors": []}'
    echo "$error_trends_json" | jq .
fi
echo "$error_trends_json" > "$output_file"
echo "Failed pipeline check completed. Results saved to $output_file"
