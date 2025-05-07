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
output_file="adf_details.json"
adf_details_json='{"data_factories": []}'

echo "Retrieving Azure Data Factory details..."
echo "Resource Group: $resource_group"
echo "Subscription ID: $subscription_id"

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
    echo "$adf_details_json" > "$output_file"
    exit 0
fi

for row in $(echo "$datafactories" | jq -c '.[]'); do
    df_name=$(echo "$row" | jq -r '.name')
    df_id=$(echo "$row" | jq -r '.id')
    df_rg=$(echo "$row" | jq -r '.resourceGroup')
    df_location=$(echo "$row" | jq -r '.location')
    df_type=$(echo "$row" | jq -r '.type')
    df_url="https://adf.azure.com/en/monitoring/pipelineruns?factory=${df_id}"
    
    echo "Processing Data Factory: $df_name"

    # Get diagnostic settings
    diagnostics=$(az monitor diagnostic-settings list --resource "$df_id" -o json 2>diag_err.log || true)
    diagnostic_status="Not Configured"
    workspace_id=""
    pipeline_logging_enabled="false"
    activity_logging_enabled="false"
    trigger_logging_enabled="false"

    if [[ -n "$diagnostics" && "$diagnostics" != "[]" ]]; then
        diagnostic_status="Configured"
        workspace_id=$(echo "$diagnostics" | jq -r '.[0].workspaceId // empty')
        
        # Check logging status for different categories
        if [[ $(echo "$diagnostics" | jq '[.[0].logs[] | select(.category == "PipelineRuns" and .enabled == true)] | length') -gt 0 ]]; then
            pipeline_logging_enabled="true"
        fi
        if [[ $(echo "$diagnostics" | jq '[.[0].logs[] | select(.category == "ActivityRuns" and .enabled == true)] | length') -gt 0 ]]; then
            activity_logging_enabled="true"
        fi
        if [[ $(echo "$diagnostics" | jq '[.[0].logs[] | select(.category == "TriggerRuns" and .enabled == true)] | length') -gt 0 ]]; then
            trigger_logging_enabled="true"
        fi
    fi
    rm -f diag_err.log 2>/dev/null || true

    # Get pipelines
    echo "Getting pipelines for $df_name..."
    pipelines=$(az datafactory pipeline list --factory-name "$df_name" --resource-group "$df_rg" --subscription "$subscription_id" -o json)

    # Get triggers
    echo "Getting triggers for $df_name..."
    triggers=$(az datafactory trigger list --factory-name "$df_name" --resource-group "$df_rg" --subscription "$subscription_id" -o json)

    # Get linked services
    echo "Getting linked services for $df_name..."
    linked_services=$(az datafactory linked-service list --factory-name "$df_name" --resource-group "$df_rg" --subscription "$subscription_id" -o json)

    # Get datasets
    echo "Getting datasets for $df_name..."
    datasets=$(az datafactory dataset list --factory-name "$df_name" --resource-group "$df_rg" --subscription "$subscription_id" -o json)

    # Add to JSON output
    adf_details_json=$(echo "$adf_details_json" | jq \
        --arg name "$df_name" \
        --arg id "$df_id" \
        --arg resource_group "$df_rg" \
        --arg location "$df_location" \
        --arg type "$df_type" \
        --arg url "$df_url" \
        --arg diagnostic_status "$diagnostic_status" \
        --arg workspace_id "$workspace_id" \
        --arg pipeline_logging "$pipeline_logging_enabled" \
        --arg activity_logging "$activity_logging_enabled" \
        --arg trigger_logging "$trigger_logging_enabled" \
        --argjson pipelines "$pipelines" \
        --argjson triggers "$triggers" \
        --argjson linked_services "$linked_services" \
        --argjson datasets "$datasets" \
        '.data_factories += [{
            "name": $name,
            "id": $id,
            "resource_group": $resource_group,
            "location": $location,
            "type": $type,
            "url": $url,
            "diagnostics": {
                "status": $diagnostic_status,
                "workspace_id": $workspace_id,
                "pipeline_logging_enabled": $pipeline_logging,
                "activity_logging_enabled": $activity_logging,
                "trigger_logging_enabled": $trigger_logging
            },
            "components": {
                "pipelines": $pipelines,
                "triggers": $triggers,
                "linked_services": $linked_services,
                "datasets": $datasets
            }
        }]')
done

# Write output to file
echo "Final JSON contents:"
echo "$adf_details_json" | jq
echo "$adf_details_json" > "$output_file"
echo "Azure Data Factory details check completed. Results saved to $output_file"
