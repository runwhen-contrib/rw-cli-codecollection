#!/bin/bash
set -euo pipefail

# -----------------------------------------------------------------------------
# REQUIRED ENV VARS:
#   AZURE_SUBSCRIPTION_ID
#   AZURE_RESOURCE_GROUP
#   AZURE_SUBSCRIPTION_NAME
#   LOOKBACK_PERIOD (optional, default: 7d)
#   RUN_TIME_THRESHOLD (optional, default: 3600) - in seconds
# -----------------------------------------------------------------------------

: "${AZURE_SUBSCRIPTION_ID:?Must set AZURE_SUBSCRIPTION_ID}"
: "${AZURE_RESOURCE_GROUP:?Must set AZURE_RESOURCE_GROUP}"
: "${AZURE_SUBSCRIPTION_NAME:?Must set AZURE_SUBSCRIPTION_NAME}"
: "${LOOKBACK_PERIOD:=7d}"
: "${RUN_TIME_THRESHOLD:=900}"

subscription_id="$AZURE_SUBSCRIPTION_ID"
resource_group="$AZURE_RESOURCE_GROUP"
subscription_name="$AZURE_SUBSCRIPTION_NAME"
output_file="long_pipeline_runs.json"
long_runs_json='{"long_running_pipelines": []}'

echo "Checking Data Factories for long-running pipelines..."
echo "Resource Group: $resource_group"
echo "Subscription ID: $subscription_id"
echo "Subscription Name: $subscription_name"
echo "Runtime Threshold: $RUN_TIME_THRESHOLD seconds"

# Configure Azure CLI to explicitly allow or disallow preview extensions
az config set extension.dynamic_install_allow_preview=true

# Check and install required extensions
echo "Checking for required extensions..."
for extension in datafactory log-analytics; do
    if ! az extension show --name "$extension" &>/dev/null; then
        echo "Installing $extension extension..."
        az extension add -n "$extension" || { echo "Failed to install $extension extension."; exit 1; }
    fi
done

# Get all Data Factories in the resource group
datafactories=$(az datafactory list -g "$resource_group" --subscription "$subscription_id" -o json)

if [[ -z "$datafactories" || "$datafactories" == "[]" ]]; then
    echo "No Data Factories found in resource group $resource_group"
    echo "$long_runs_json" > "$output_file"
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

        long_runs_json=$(echo "$long_runs_json" | jq \
            --arg title "No Diagnostic Settings for Data Factory \`$df_name\` in resource group \`${resource_group}\` in subscription \`${subscription_name}\`" \
            --arg details "$err_msg" \
            --arg severity "4" \
            --arg nextStep "Enable diagnostics and configure Log Analytics for Data Factory \`$df_name\` in resource group \`${resource_group}\` in subscription \`${subscription_name}\`" \
            --arg expected "Diagnostic settings should be enabled for Data Factory \`$df_name\` in resource group \`${resource_group}\` in subscription \`${subscription_name}\`" \
            --arg actual "Diagnostic settings not enabled for Data Factory \`$df_name\` in resource group \`${resource_group}\` in subscription \`${subscription_name}\`" \
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

    # Extract Log Analytics workspace ID
    workspace_id=$(echo "$diagnostics" | jq -r '.[0].workspaceId // empty')

    # Count how many PipelineRuns and ActivityRuns logs are enabled
    enabled_pipeline_runs_count=$(echo "$diagnostics" | jq '[.[0].logs[] | select(.category == "PipelineRuns" and .enabled == true)] | length')
    enabled_activity_runs_count=$(echo "$diagnostics" | jq '[.[0].logs[] | select(.category == "ActivityRuns" and .enabled == true)] | length')

    # If PipelineRuns logging is not enabled, report failure
    if [[ "$enabled_pipeline_runs_count" -eq 0 ]]; then
        long_runs_json=$(echo "$long_runs_json" | jq \
            --arg title "PipelineRuns Logging Disabled in Data Factory \`$df_name\` in resource group \`${resource_group}\` in subscription \`${subscription_name}\`" \
            --arg details "PipelineRuns logging must be enabled to monitor pipeline execution times." \
            --arg severity "4" \
            --arg nextStep "Enable PipelineRuns logging in diagnostic settings for Data Factory \`$df_name\`" \
            --arg expected "PipelineRuns logging should be enabled for Data Factory \`$df_name\` in resource group \`${resource_group}\` in subscription \`${subscription_name}\`" \
            --arg actual "PipelineRuns logging is disabled for Data Factory \`$df_name\` in resource group \`${resource_group}\` in subscription \`${subscription_name}\`" \
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

    if [[ -z "$workspace_id" || "$workspace_id" == "null" ]]; then
        long_runs_json=$(echo "$long_runs_json" | jq \
            --arg title "No Log Analytics Workspace for Data Factory \`$df_name\` in resource group \`${resource_group}\` in subscription \`${subscription_name}\`" \
            --arg details "Diagnostics are configured but no workspace is defined." \
            --arg severity "4" \
            --arg nextStep "Configure Log Analytics workspace in diagnostic settings for Data Factory \`$df_name\`" \
            --arg expected "Log Analytics workspace should be configured for Data Factory \`$df_name\` in resource group \`${resource_group}\` in subscription \`${subscription_name}\`" \
            --arg actual "No Log Analytics workspace configured for Data Factory \`$df_name\` in resource group \`${resource_group}\` in subscription \`${subscription_name}\`" \
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
    if ! workspace_guid=$(az monitor log-analytics workspace show --ids "$workspace_id" --query "customerId" -o tsv 2>guid_err.log); then
        err_msg=$(cat guid_err.log)
        rm -f guid_err.log

        long_runs_json=$(echo "$long_runs_json" | jq \
            --arg title "Failed to Get Log Analytics Workspace ID for Data Factory \`$df_name\` in resource group \`${resource_group}\` in subscription \`${subscription_name}\`" \
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

    # KQL Query to get long-running pipeline runs
    kql_query=$(cat <<EOF
AzureDiagnostics
| where ResourceProvider == "MICROSOFT.DATAFACTORY"
| where Category == "PipelineRuns"
| where Resource =~ "$df_name"
| where TimeGenerated > ago($LOOKBACK_PERIOD)
| extend duration = datetime_diff('second', end_t, start_t)
| where duration > $RUN_TIME_THRESHOLD
| project pipelineName_s, start_t, end_t, duration, status_s, runId_g
| order by duration desc
EOF
)

    echo "Querying long-running pipeline runs for $df_name..."
    if ! long_running_pipelines=$(az monitor log-analytics query \
        --workspace "$workspace_guid" \
        --analytics-query "$kql_query" \
        --subscription "$subscription_id" \
        --output json 2>pipeline_query_err.log); then
        err_msg=$(cat pipeline_query_err.log)
        rm -f pipeline_query_err.log
        
        long_runs_json=$(echo "$long_runs_json" | jq \
            --arg title "Log Analytics Query Failed for Data Factory \`$df_name\` in resource group \`${resource_group}\` in subscription \`${subscription_name}\`" \
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

    if ! echo "${long_running_pipelines}" | jq empty 2>/dev/null; then
        echo "Error: Invalid JSON in long_running_pipelines"
        continue
    fi
    
    while read -r pipeline; do
        pipeline_name=$(echo "$pipeline" | jq -r '.pipelineName_s')
        start_time=$(echo "$pipeline" | jq -r '.Start_time_t')
        end_time=$(echo "$pipeline" | jq -r '.End_time_t')
        duration=$(echo "$pipeline" | jq -r '.duration')
        status=$(echo "$pipeline" | jq -r '.status_s')
        run_id=$(echo "$pipeline" | jq -r '.runId_g')
        
        long_runs_json=$(echo "$long_runs_json" | jq \
            --arg title "Long Running Pipeline \`$pipeline_name\` in Data Factory \`$df_name\` in resource group \`${resource_group}\` in subscription \`${subscription_name}\`" \
            --arg details "$pipeline" \
            --arg severity "4" \
            --arg nextStep "Review pipeline configuration and optimize if possible" \
            --arg name "$pipeline_name" \
            --arg expected "Pipeline runtime should be less than $RUN_TIME_THRESHOLD seconds" \
            --arg actual "Pipeline runtime was $duration seconds" \
            --arg resource_url "$df_url" \
            --arg reproduce_hint "az monitor log-analytics query --workspace \"$workspace_guid\" --analytics-query '$kql_query' --subscription \"$subscription_id\" --output json" \
            --arg run_id "$run_id" \
            --arg start_time "$start_time" \
            --arg end_time "$end_time" \
            --arg status "$status" \
            --arg duration "$duration" \
            '.long_running_pipelines += [{
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
                "start_time": $start_time,
                "end_time": $end_time,
                "duration": ($duration | tonumber),
                "status": $status
            }]')
    done < <(echo "$long_running_pipelines" | jq -c '.[]')
done

# Write output to file
echo "Final JSON contents:"
echo "$long_runs_json" | jq
echo "$long_runs_json" > "$output_file"
echo "Long running pipeline check completed. Results saved to $output_file"