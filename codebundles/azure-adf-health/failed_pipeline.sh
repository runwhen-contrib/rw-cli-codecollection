#!/bin/bash
set -euo pipefail

# -----------------------------------------------------------------------------
# REQUIRED ENV VARS:
#   AZURE_SUBSCRIPTION_ID
#   AZURE_RESOURCE_GROUP
# -----------------------------------------------------------------------------

: "${AZURE_SUBSCRIPTION_ID:?Must set AZURE_SUBSCRIPTION_ID}"
: "${AZURE_RESOURCE_GROUP:?Must set AZURE_RESOURCE_GROUP}"

subscription_id="$AZURE_SUBSCRIPTION_ID"
resource_group="$AZURE_RESOURCE_GROUP"
output_file="failed_pipelines.json"
failed_pipelines_json='{"failed_pipelines": []}'

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
    df_url="https://portal.azure.com/#@/resource${df_id}"

    echo "Processing Data Factory: $df_name"

    # Get diagnostic settings
    diagnostics=$(az monitor diagnostic-settings list --resource "$df_id" -o json 2>diag_err.log || true)
    
    if [[ -z "$diagnostics" || "$diagnostics" == "[]" ]]; then
        err_msg=$(cat diag_err.log)
        rm -f diag_err.log

        failed_pipelines_json=$(echo "$failed_pipelines_json" | jq \
            --arg title "No Diagnostic Settings for Data Factory $df_name" \
            --arg details "$err_msg" \
            --arg severity "4" \
            --arg nextStep "Enable diagnostics and configure Log Analytics for Data Factory \`$df_name\`." \
            --arg resource_url "$df_url" \
            '.failed_pipelines += [{
                "title": $title,
                "details": $details,
                "next_step": $nextStep,
                "severity": ($severity | tonumber),
                "resource_url": $resource_url
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
            --arg title "PipelineRuns Logging Disabled in $df_name" \
            --arg details "Diagnostics are enabled but the 'PipelineRuns' log category is not enabled. This is required to fetch pipeline run failures." \
            --arg severity "3" \
            --arg nextStep "Enable 'PipelineRuns' logging in diagnostic settings of Data Factory \`$df_name\`." \
            --arg resource_url "$df_url" \
            '.failed_pipelines += [{
                "title": $title,
                "details": $details,
                "next_step": $nextStep,
                "severity": ($severity | tonumber),
                "resource_url": $resource_url
            }]')
        continue
    fi

    # Optional: Warn if ActivityRuns is not enabled
    if [[ "$enabled_activity_runs_count" -eq 0 ]]; then
        failed_pipelines_json=$(echo "$failed_pipelines_json" | jq \
            --arg title "ActivityRuns Logging Disabled in $df_name" \
            --arg details "You may miss detailed activity-level diagnostics without 'ActivityRuns' logging." \
            --arg severity "4" \
            --arg nextStep "Consider enabling 'ActivityRuns' logging in diagnostic settings of Data Factory \`$df_name\`." \
            --arg resource_url "$df_url" \
            '.failed_pipelines += [{
                "title": $title,
                "details": $details,
                "next_step": $nextStep,
                "severity": ($severity | tonumber),
                "resource_url": $resource_url
            }]')
    fi

    if [[ -z "$workspace_id" || "$workspace_id" == "null" ]]; then
        failed_pipelines_json=$(echo "$failed_pipelines_json" | jq \
            --arg title "No Log Analytics Workspace for $df_name" \
            --arg details "Diagnostics are configured but no workspace is defined." \
            --arg severity "3" \
            --arg nextStep "Add Log Analytics workspace to diagnostics for Data Factory \`$df_name\`." \
            --arg resource_url "$df_url" \
            '.failed_pipelines += [{
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

        failed_pipelines_json=$(echo "$failed_pipelines_json" | jq \
            --arg title "Failed to Get Workspace GUID for $df_name" \
            --arg details "$err_msg" \
            --arg severity "2" \
            --arg nextStep "Verify access to the workspace or check if the workspace ID is valid." \
            --arg resource_url "$df_url" \
            '.failed_pipelines += [{
                "title": $title,
                "details": $details,
                "next_step": $nextStep,
                "severity": ($severity | tonumber),
                "resource_url": $resource_url
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
| summarize by pipelineName_s, Message
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
            --arg title "Log Analytics Query Failed for $df_name" \
            --arg details "$err_msg" \
            --arg severity "2" \
            --arg nextStep "Verify workspace permissions or check if diagnostics have been sending data." \
            --arg resource_url "$df_url" \
            '.failed_pipelines += [{
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
        message=$(echo "$pipeline" | jq -r '.Message')

        failed_pipelines_json=$(echo "$failed_pipelines_json" | jq \
            --arg title "Failed Pipeline \`$pipeline_name\` in Data Factory \`$df_name\`" \
            --arg details "$pipeline" \
            --arg severity "3" \
            --arg nextStep "Inspect the pipeline run logs in Azure Data Factory portal." \
            --arg name "$pipeline_name" \
            --arg resource_url "$df_url" \
            '.failed_pipelines += [{
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
echo "$failed_pipelines_json" | jq
echo "$failed_pipelines_json" > "$output_file"
echo "Failed pipeline check completed. Results saved to $output_file"
