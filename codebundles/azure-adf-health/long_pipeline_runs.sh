#!/bin/bash
set -euo pipefail

# -----------------------------------------------------------------------------
# REQUIRED ENV VARS:
#   AZURE_RESOURCE_GROUP
#   AZURE_RESOURCE_SUBSCRIPTION_ID
#   LOOKBACK_PERIOD (optional, default: 7d)
#   RUN_TIME_THRESHOLD (optional, default: 3600) - in seconds
# -----------------------------------------------------------------------------

: "${AZURE_RESOURCE_GROUP:?Must set AZURE_RESOURCE_GROUP}"
: "${AZURE_RESOURCE_SUBSCRIPTION_ID:?Must set AZURE_RESOURCE_SUBSCRIPTION_ID}"
: "${LOOKBACK_PERIOD:=7d}"
: "${RUN_TIME_THRESHOLD:=900}"

subscription_id="$AZURE_RESOURCE_SUBSCRIPTION_ID"
resource_group="$AZURE_RESOURCE_GROUP"
output_file="long_pipeline_runs.json"
long_runs_json='{"long_running_pipelines": []}'

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
        echo "$long_runs_json" > "$output_file"
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
    echo "$long_runs_json" > "$output_file"
    exit 1
fi

echo "Checking Data Factories for long-running pipelines..."
echo "Resource Group: $resource_group"
echo "Subscription ID: $subscription_id"
echo "Runtime Threshold: $RUN_TIME_THRESHOLD seconds"

# Configure Azure CLI to explicitly allow or disallow preview extensions
echo "Configuring Azure CLI extensions..."
if ! az config set extension.dynamic_install_allow_preview=true 2>/dev/null; then
    echo "WARNING: Could not configure Azure CLI extension settings"
fi

# Check and install required extensions
echo "Checking for required extensions..."
for extension in datafactory log-analytics; do
    if ! az extension show --name "$extension" >/dev/null 2>&1; then
        echo "Installing $extension extension..."
        if ! az extension add -n "$extension" 2>/dev/null; then
            echo "ERROR: Failed to install $extension extension."
            echo "$long_runs_json" > "$output_file"
            exit 1
        fi
    fi
done

# Get all Data Factories in the resource group
echo "Fetching Data Factories..."
if ! datafactories=$(az datafactory list -g "$resource_group" --subscription "$subscription_id" -o json 2>/dev/null); then
    echo "ERROR: Failed to list Data Factories in resource group $resource_group"
    echo "$long_runs_json" > "$output_file"
    exit 1
fi

if ! validate_json "$datafactories"; then
    echo "ERROR: Invalid JSON response from Data Factory list command"
    echo "$long_runs_json" > "$output_file"
    exit 1
fi

if [[ "$datafactories" == "[]" ]] || [[ -z "$datafactories" ]]; then
    echo "No Data Factories found in resource group $resource_group"
    echo "$long_runs_json" > "$output_file"
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

        long_runs_json=$(echo "$long_runs_json" | jq \
            --arg title "No Diagnostic Settings for Data Factory \`$df_name\` in resource group \`${resource_group}\`" \
            --arg details "$err_msg" \
            --arg severity "4" \
            --arg nextStep "Enable diagnostics and configure Log Analytics for Data Factory \`$df_name\` in resource group \`${resource_group}\`" \
            --arg expected "Diagnostic settings should be enabled for Data Factory \`$df_name\` in resource group \`${resource_group}\`" \
            --arg actual "Diagnostic settings not enabled for Data Factory \`$df_name\` in resource group \`${resource_group}\`" \
            --arg resource_url "$df_url" \
            --arg reproduce_hint "az monitor diagnostic-settings list --resource \"$df_id\"" \
            '.long_running_pipelines += [{
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

    if ! validate_json "$diagnostics" || [[ "$diagnostics" == "[]" ]]; then
        long_runs_json=$(echo "$long_runs_json" | jq \
            --arg title "No Diagnostic Settings for Data Factory \`$df_name\` in resource group \`${resource_group}\`" \
            --arg details "No diagnostic settings configured or invalid response" \
            --arg severity "4" \
            --arg nextStep "Enable diagnostics and configure Log Analytics for Data Factory \`$df_name\` in resource group \`${resource_group}\`" \
            --arg expected "Diagnostic settings should be enabled for Data Factory \`$df_name\` in resource group \`${resource_group}\`" \
            --arg actual "Diagnostic settings not enabled for Data Factory \`$df_name\` in resource group \`${resource_group}\`" \
            --arg resource_url "$df_url" \
            --arg reproduce_hint "az monitor diagnostic-settings list --resource \"$df_id\"" \
            '.long_running_pipelines += [{
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

    # Extract Log Analytics workspace ID
    workspace_id=$(safe_jq "$diagnostics" '.[0].workspaceId // empty' "")

    # Count how many PipelineRuns and ActivityRuns logs are enabled
    enabled_pipeline_runs_count=$(safe_jq "$diagnostics" '[.[0].logs[] | select(.category == "PipelineRuns" and .enabled == true)] | length' "0")

    # If PipelineRuns logging is not enabled, report failure
    if [[ "$enabled_pipeline_runs_count" -eq 0 ]]; then
        long_runs_json=$(echo "$long_runs_json" | jq \
            --arg title "PipelineRuns Logging Disabled in Data Factory \`$df_name\` in resource group \`${resource_group}\`" \
            --arg details "PipelineRuns logging must be enabled to monitor pipeline execution times." \
            --arg severity "4" \
            --arg nextStep "Enable PipelineRuns logging in diagnostic settings for Data Factory \`$df_name\`" \
            --arg expected "PipelineRuns logging should be enabled for Data Factory \`$df_name\` in resource group \`${resource_group}\`" \
            --arg actual "PipelineRuns logging is disabled for Data Factory \`$df_name\` in resource group \`${resource_group}\`" \
            --arg resource_url "$df_url" \
            --arg reproduce_hint "az monitor diagnostic-settings list --resource \"$df_id\"" \
            '.long_running_pipelines += [{
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

    if [[ -z "$workspace_id" ]] || [[ "$workspace_id" == "null" ]]; then
        long_runs_json=$(echo "$long_runs_json" | jq \
            --arg title "No Log Analytics Workspace for Data Factory \`$df_name\` in resource group \`${resource_group}\`" \
            --arg details "Diagnostics are configured but no workspace is defined." \
            --arg severity "4" \
            --arg nextStep "Configure Log Analytics workspace in diagnostic settings for Data Factory \`$df_name\`" \
            --arg expected "Log Analytics workspace should be configured for Data Factory \`$df_name\` in resource group \`${resource_group}\`" \
            --arg actual "No Log Analytics workspace configured for Data Factory \`$df_name\` in resource group \`${resource_group}\`" \
            --arg resource_url "$df_url" \
            --arg reproduce_hint "az monitor diagnostic-settings list --resource \"$df_id\"" \
            '.long_running_pipelines += [{
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
    workspace_guid=""
    if ! workspace_guid=$(az monitor log-analytics workspace show --ids "$workspace_id" --query "customerId" -o tsv 2>guid_err.log); then
        err_msg="Failed to get workspace GUID"
        if [[ -f guid_err.log ]]; then
            err_msg=$(cat guid_err.log 2>/dev/null || echo "$err_msg")
        fi
        rm -f guid_err.log

        long_runs_json=$(echo "$long_runs_json" | jq \
            --arg title "Failed to Get Log Analytics Workspace ID for Data Factory \`$df_name\` in resource group \`${resource_group}\`" \
            --arg details "$err_msg" \
            --arg severity "3" \
            --arg nextStep "Verify Log Analytics workspace permissions and configuration" \
            --arg expected "Should be able to retrieve Log Analytics workspace ID" \
            --arg actual "Failed to retrieve Log Analytics workspace ID" \
            --arg resource_url "$df_url" \
            --arg reproduce_hint "az monitor log-analytics workspace show --ids \"$workspace_id\" --query \"customerId\" -o tsv" \
            '.long_running_pipelines += [{
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

    if [[ -z "$workspace_guid" ]]; then
        long_runs_json=$(echo "$long_runs_json" | jq \
            --arg title "Empty workspace GUID for Data Factory \`$df_name\` in resource group \`${resource_group}\`" \
            --arg details "Workspace GUID is empty or null" \
            --arg severity "4" \
            --arg nextStep "Verify workspace configuration" \
            --arg expected "Should have valid workspace GUID" \
            --arg actual "Empty workspace GUID" \
            --arg resource_url "$df_url" \
            --arg reproduce_hint "az monitor log-analytics workspace show --ids \"$workspace_id\" --query \"customerId\" -o tsv" \
            '.long_running_pipelines += [{
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

    # KQL Query to get long-running pipeline runs
    kql_query=$(cat <<EOF
AzureDiagnostics
| where ResourceProvider == "MICROSOFT.DATAFACTORY"
| where Category == "PipelineRuns"
| where Resource =~ "$df_name"
| where TimeGenerated > ago($LOOKBACK_PERIOD)
| extend duration = datetime_diff('second', end_t, start_t)
| where duration > $RUN_TIME_THRESHOLD
| project pipelineName_s, Start_time_t = start_t, End_time_t = end_t, duration, status_s, runId_g
| order by duration desc
EOF
)

    echo "Querying long-running pipeline runs for $df_name..."
    long_running_pipelines=""
    if ! long_running_pipelines=$(az monitor log-analytics query \
        --workspace "$workspace_guid" \
        --analytics-query "$kql_query" \
        --subscription "$subscription_id" \
        --output json 2>pipeline_query_err.log); then
        err_msg="Log Analytics query failed"
        if [[ -f pipeline_query_err.log ]]; then
            err_msg=$(cat pipeline_query_err.log 2>/dev/null || echo "$err_msg")
        fi
        rm -f pipeline_query_err.log
        
        long_runs_json=$(echo "$long_runs_json" | jq \
            --arg title "Log Analytics Query Failed for Data Factory \`$df_name\` in resource group \`${resource_group}\`" \
            --arg details "$err_msg" \
            --arg severity "4" \
            --arg nextStep "Verify workspace permissions or check if diagnostics have been sending data." \
            --arg expected "Log Analytics query should be successful" \
            --arg actual "Log Analytics query failed" \
            --arg resource_url "$df_url" \
            --arg reproduce_hint "az monitor log-analytics query --workspace \"$workspace_guid\" --analytics-query '$kql_query' --subscription \"$subscription_id\" --output json" \
            '.long_running_pipelines += [{
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

    if ! validate_json "$long_running_pipelines"; then
        echo "Warning: Invalid JSON in long_running_pipelines for $df_name, skipping..."
        continue
    fi
    
    # Process long running pipelines if valid
    while IFS= read -r pipeline; do
        if [[ -z "$pipeline" ]] || ! validate_json "$pipeline"; then
            continue
        fi
        
        pipeline_name=$(safe_jq "$pipeline" '.pipelineName_s' "unknown")
        start_time=$(safe_jq "$pipeline" '.Start_time_t' "unknown")
        end_time=$(safe_jq "$pipeline" '.End_time_t' "unknown")
        duration=$(safe_jq "$pipeline" '.duration' "0")
        status=$(safe_jq "$pipeline" '.status_s' "unknown")
        run_id=$(safe_jq "$pipeline" '.runId_g' "unknown")
        
        long_runs_json=$(echo "$long_runs_json" | jq \
            --arg title "Long Running Pipeline \`$pipeline_name\` in Data Factory \`$df_name\` in resource group \`${resource_group}\`" \
            --arg details "$pipeline" \
            --arg severity "3" \
            --arg nextStep "Review pipeline design and consider optimizations for Data Factory \`$df_name\` in resource group \`${resource_group}\`" \
            --arg name "$pipeline_name" \
            --arg duration "$duration" \
            --arg status "$status" \
            --arg expected "Pipeline \`$pipeline_name\` should complete within ${RUN_TIME_THRESHOLD} seconds in resource group \`${resource_group}\`" \
            --arg actual "Pipeline \`$pipeline_name\` took $duration seconds to complete in resource group \`${resource_group}\`" \
            --arg resource_url "$df_url" \
            --arg reproduce_hint "az monitor log-analytics query --workspace \"$workspace_guid\" --analytics-query '$kql_query' --subscription \"$subscription_id\" --output json" \
            --arg run_id "$run_id" \
            '.long_running_pipelines += [{
                "title": $title,
                "details": $details,
                "next_step": $nextStep,
                "expected": $expected,
                "actual": $actual,
                "severity": ($severity | tonumber),
                "name": $name,
                "duration": $duration,
                "status": $status,
                "resource_url": $resource_url,
                "reproduce_hint": $reproduce_hint,
                "run_id": $run_id
            }]')
    done < <(echo "$long_running_pipelines" | jq -c '.[]' 2>/dev/null || echo "")
done < <(echo "$datafactories" | jq -c '.[]' 2>/dev/null || echo "")

# Write output to file
echo "Final JSON contents:"
if validate_json "$long_runs_json"; then
    echo "$long_runs_json" | jq . 2>/dev/null || echo "$long_runs_json"
else
    echo "Warning: Final JSON is invalid, using fallback"
    long_runs_json='{"long_running_pipelines": []}'
fi
echo "$long_runs_json" > "$output_file"
echo "Long-running pipeline check completed. Results saved to $output_file"