#!/bin/bash
set -euo pipefail

# -----------------------------------------------------------------------------
# REQUIRED ENV VARS:
#   AZURE_SUBSCRIPTION_ID
#   AZURE_RESOURCE_GROUP
#   AZURE_SUBSCRIPTION_NAME
# -----------------------------------------------------------------------------

: "${AZURE_SUBSCRIPTION_ID:?Must set AZURE_SUBSCRIPTION_ID}"
: "${AZURE_RESOURCE_GROUP:?Must set AZURE_RESOURCE_GROUP}"
: "${AZURE_SUBSCRIPTION_NAME:?Must set AZURE_SUBSCRIPTION_NAME}"

subscription_id="$AZURE_SUBSCRIPTION_ID"
resource_group="$AZURE_RESOURCE_GROUP"
subscription_name="$AZURE_SUBSCRIPTION_NAME"
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
    df_url="https://portal.azure.com/#@/resource${df_id}"

    echo "Processing Data Factory: $df_name"

    # Get diagnostic settings
    diagnostics=$(az monitor diagnostic-settings list --resource "$df_id" -o json 2>diag_err.log || true)
    
    if [[ -z "$diagnostics" || "$diagnostics" == "[]" ]]; then
        err_msg=$(cat diag_err.log)
        rm -f diag_err.log

        error_trends_json=$(echo "$error_trends_json" | jq \
            --arg title "No Diagnostic Settings for Data Factory $df_name in resource group \`${resource_group}\` in subscription \`${subscription_name}\`" \
            --arg details "$err_msg" \
            --arg severity "4" \
            --arg nextStep "Enable diagnostics and configure Log Analytics for Data Factory \`$df_name\` in resource group \`${resource_group}\` in subscription \`${subscription_name}\`" \
            --arg expected "Diagnostic settings should be enabled for Data Factory \`$df_name\` in resource group \`${resource_group}\` in subscription \`${subscription_name}\`" \
            --arg resource_url "$df_url" \
            --arg reproduce_hint "az monitor diagnostic-settings list --resource \"$df_id\"" \
            '.error_trends += [{
                "title": $title,
                "details": $details,
                "next_step": $nextStep,
                "severity": ($severity | tonumber),
                "resource_url": $resource_url,
                "reproduce_hint": $reproduce_hint,
                "expected": $expected
            }]')
        continue
    fi
    rm -f diag_err.log

    # Extract Log Analytics workspace ID
    workspace_id=$(echo "$diagnostics" | jq -r '.[0].workspaceId // empty')

    # Count how many PipelineRuns and ActivityRuns logs are enabled
    enabled_pipeline_runs_count=$(echo "$diagnostics" | jq '[.[0].logs[] | select(.category == "PipelineRuns" and .enabled == true)] | length')
    enabled_activity_runs_count=$(echo "$diagnostics" | jq '[.[0].logs[] | select(.category == "ActivityRuns" and .enabled == true)] | length')
    echo "az monitor diagnostic-settings list --resource \"$df_id\" -o json | jq '[.[0].logs[] | select(.category == \"PipelineRuns\" and .enabled == true)]'"
    # If PipelineRuns logging is not enabled, report failure
    if [[ "$enabled_pipeline_runs_count" -eq 0 ]]; then
        error_trends_json=$(echo "$error_trends_json" | jq \
            --arg title "PipelineRuns Logging Disabled in $df_name in resource group \`${resource_group}\` in subscription \`${subscription_name}\`" \
            --arg details $diagnostics \
            --arg severity "3" \
            --arg nextStep "Enable 'PipelineRuns' logging in diagnostic settings of Data Factory \`$df_name\` in resource group \`${resource_group}\` in subscription \`${subscription_name}\`" \
            --arg expected "PipelineRuns logging should be enabled for Data Factory \`$df_name\` in resource group \`${resource_group}\` in subscription \`${subscription_name}\`" \
            --arg reproduce_hint "az monitor diagnostic-settings list --resource \"$df_id\" -o json | jq '[.[0].logs[] | select(.category == \"PipelineRuns\" and .enabled == true)]'" \
            --arg resource_url $df_url \
            '.error_trends += [{
                "title": $title,
                "details": $details,
                "next_step": $nextStep,
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
            --arg title "ActivityRuns Logging Disabled in $df_name" \
            --arg details "You may miss detailed activity-level diagnostics without 'ActivityRuns' logging." \
            --arg severity "4" \
            --arg nextStep "Consider enabling 'ActivityRuns' logging in diagnostic settings of Data Factory \`$df_name\`." \
            --arg expected "ActivityRuns logging should be enabled for Data Factory \`$df_name\` in resource group \`${resource_group}\` in subscription \`${subscription_name}\`" \
            --arg reproduce_hint "az monitor diagnostic-settings list --resource \"$df_id\" -o json | jq '[.[0].logs[] | select(.category == \"ActivityRuns\" and .enabled == true)]'" \
            --arg resource_url $df_url \
            '.error_trends += [{
                "title": $title,
                "details": $details,
                "next_step": $nextStep,
                "expected": $expected,
                "severity": ($severity | tonumber),
                "resource_url": $resource_url
            }]')
    fi

    if [[ -z "$workspace_id" || "$workspace_id" == "null" ]]; then
        error_trends_json=$(echo "$error_trends_json" | jq \
            --arg title "No Log Analytics Workspace for $df_name" \
            --arg details "Diagnostics are configured but no workspace is defined." \
            --arg severity "3" \
            --arg nextStep "Add Log Analytics workspace to diagnostics for Data Factory \`$df_name\`." \
            --arg resource_url $df_url \
            '.error_trends += [{
                "title": $title,
                "details": $details,
                "next_step": $nextStep,
                "severity": ($severity | tonumber),
                "resource_url": $resource_url
            }]')
        continue
    fi

    # Get customer ID (GUID) for the workspace
    if ! workspace_guid=$(az monitor log-analytics workspace show --ids "$workspace_id" --query "customerId" -o tsv 2>guid_err.log); then
        err_msg=$(cat guid_err.log)
        rm -f guid_err.log

        error_trends_json=$(echo "$error_trends_json" | jq \
            --arg title "Failed to Get Workspace GUID for $df_name" \
            --arg details "$err_msg" \
            --arg severity "2" \
            --arg nextStep "Verify access to the workspace or check if the workspace ID is valid." \
            --arg resource_url "$df_url" \
            '.error_trends += [{
                "title": $title,
                "details": $details,
                "next_step": $nextStep,
                "severity": ($severity | tonumber),
                "resource_url": $resource_url
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
| where TimeGenerated > ago(7d)
| where Resource =~ "$df_name"
| extend MsgPrefix = substring(Message, 0, 100)
| summarize FailureCount = count(), LastSeen = max(TimeGenerated), Messages = make_list(Message, 2) by MsgPrefix, pipelineName_s, ResourceId
| sort by FailureCount desc
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
        
        error_trends_json=$(echo "$error_trends_json" | jq \
            --arg title "Log Analytics Query Failed for $df_name" \
            --arg details "$err_msg" \
            --arg severity "2" \
            --arg nextStep "Verify workspace permissions or check if diagnostics have been sending data." \
            --arg resource_url "$df_url" \
            '.error_trends += [{
                "title": $title,
                "details": $details,
                "next_step": $nextStep,
                "severity": ($severity | tonumber),
                "resource_url": $resource_url
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
        message=$(echo "$pipeline" | jq -r '.Messages | fromjson[0]')
        
        error_trends_json=$(echo "$error_trends_json" | jq \
            --arg title "Failed Pipeline \`$pipeline_name\` in Data Factory \`$df_name\`" \
            --arg details "$pipeline" \
            --arg severity "3" \
            --arg nextStep "Inspect the pipeline run logs in Azure Data Factory portal." \
            --arg name "$pipeline_name" \
            --arg resource_url "$df_url" \
            '.error_trends += [{
                "title": $title,
                "details": $details,
                "next_step": $nextStep,
                "severity": ($severity | tonumber),
                "name": $name,
                "resource_url": $resource_url
            }]')
    done < <(echo "$failed_pipelines" | jq -c '.[]')
done

# Write output to file
echo "Final JSON contents:"
echo "$error_trends_json" | jq
echo "$error_trends_json" > "$output_file"
echo "Failed pipeline check completed. Results saved to $output_file"
