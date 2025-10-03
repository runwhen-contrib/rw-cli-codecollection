#!/bin/bash
# Function to extract timestamp from log line, fallback to current time
extract_log_timestamp() {
    local log_line="$1"
    local fallback_timestamp=$(date -u +"%Y-%m-%dT%H:%M:%S.%3NZ")
    
    if [[ -z "$log_line" ]]; then
        echo "$fallback_timestamp"
        return
    fi
    
    # Try to extract common timestamp patterns
    # ISO 8601 format: 2024-01-15T10:30:45.123Z
    if [[ "$log_line" =~ ([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]{3})?Z?) ]]; then
        echo "${BASH_REMATCH[1]}"
        return
    fi
    
    # Standard log format: 2024-01-15 10:30:45
    if [[ "$log_line" =~ ([0-9]{4}-[0-9]{2}-[0-9]{2}[[:space:]]+[0-9]{2}:[0-9]{2}:[0-9]{2}) ]]; then
        # Convert to ISO format
        local extracted_time="${BASH_REMATCH[1]}"
        local iso_time=$(date -d "$extracted_time" -u +"%Y-%m-%dT%H:%M:%S.000Z" 2>/dev/null)
        if [[ $? -eq 0 ]]; then
            echo "$iso_time"
        else
            echo "$fallback_timestamp"
        fi
        return
    fi
    
    # DD-MM-YYYY HH:MM:SS format
    if [[ "$log_line" =~ ([0-9]{2}-[0-9]{2}-[0-9]{4}[[:space:]]+[0-9]{2}:[0-9]{2}:[0-9]{2}) ]]; then
        local extracted_time="${BASH_REMATCH[1]}"
        # Convert DD-MM-YYYY to YYYY-MM-DD for date parsing
        local day=$(echo "$extracted_time" | cut -d' ' -f1 | cut -d'-' -f1)
        local month=$(echo "$extracted_time" | cut -d' ' -f1 | cut -d'-' -f2)
        local year=$(echo "$extracted_time" | cut -d' ' -f1 | cut -d'-' -f3)
        local time_part=$(echo "$extracted_time" | cut -d' ' -f2)
        local iso_time=$(date -d "$year-$month-$day $time_part" -u +"%Y-%m-%dT%H:%M:%S.000Z" 2>/dev/null)
        if [[ $? -eq 0 ]]; then
            echo "$iso_time"
        else
            echo "$fallback_timestamp"
        fi
        return
    fi
    
    # Fallback to current timestamp
    echo "$fallback_timestamp"
}

set -euo pipefail

# -----------------------------------------------------------------------------
# REQUIRED ENV VARS:
#   AZURE_RESOURCE_GROUP
#   AZURE_RESOURCE_SUBSCRIPTION_ID
# -----------------------------------------------------------------------------

: "${AZURE_RESOURCE_GROUP:?Must set AZURE_RESOURCE_GROUP}"
: "${AZURE_RESOURCE_SUBSCRIPTION_ID:?Must set AZURE_RESOURCE_SUBSCRIPTION_ID}"

subscription_id="$AZURE_RESOURCE_SUBSCRIPTION_ID"
resource_group="$AZURE_RESOURCE_GROUP"
output_file="adf_details.json"
adf_details_json='{"data_factories": []}'

echo "Retrieving Azure Data Factory details..."
echo "Resource Group: $resource_group"
echo "Subscription ID: $subscription_id"

# Get or set subscription ID
if [[ -z "${AZURE_RESOURCE_SUBSCRIPTION_ID:-}" ]]; then
    subscription=$(az account show --query "id" -o tsv 2>/dev/null || echo "")
    if [[ -z "$subscription" ]]; then
        echo "ERROR: Could not determine current subscription ID and AZURE_RESOURCE_SUBSCRIPTION_ID is not set."
        echo "$adf_details_json" > "$output_file"
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
    echo "$adf_details_json" > "$output_file"
    exit 1
fi

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
        exit 1
    fi
fi

# Get all Data Factories in the resource group
echo "Fetching Data Factories..."
if ! datafactories=$(az datafactory list -g "$resource_group" --subscription "$subscription_id" -o json 2>/dev/null); then
    echo "ERROR: Failed to list Data Factories in resource group $resource_group"
    echo "$adf_details_json" > "$output_file"
    exit 1
fi

if ! validate_json "$datafactories"; then
    echo "ERROR: Invalid JSON response from Data Factory list command"
    echo "$adf_details_json" > "$output_file"
    exit 1
fi

if [[ "$datafactories" == "[]" ]] || [[ -z "$datafactories" ]]; then
    echo "No Data Factories found in resource group $resource_group"
    echo "$adf_details_json" > "$output_file"
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
    df_location=$(safe_jq "$row" '.location' "")
    df_type=$(safe_jq "$row" '.type' "")
    df_url="https://adf.azure.com/en/monitoring/pipelineruns?factory=${df_id}"
    
    if [[ -z "$df_id" ]] || [[ "$df_name" == "unknown" ]]; then
        echo "Skipping Data Factory with missing required fields"
        continue
    fi
    
    echo "Processing Data Factory: $df_name"

    # Get diagnostic settings with better error handling
    diagnostics=""
    diagnostic_status="Not Configured"
    workspace_id=""
    pipeline_logging_enabled="false"
    activity_logging_enabled="false"
    trigger_logging_enabled="false"

    if diagnostics=$(az monitor diagnostic-settings list --resource "$df_id" -o json 2>diag_err.log); then
        if validate_json "$diagnostics" && [[ "$diagnostics" != "[]" ]]; then
            diagnostic_status="Configured"
            workspace_id=$(safe_jq "$diagnostics" '.[0].workspaceId // empty' "")
            
            # Check logging status for different categories
            pipeline_count=$(safe_jq "$diagnostics" '[.[0].logs[] | select(.category == "PipelineRuns" and .enabled == true)] | length' "0")
            if [[ "$pipeline_count" -gt 0 ]]; then
                pipeline_logging_enabled="true"
            fi
            
            activity_count=$(safe_jq "$diagnostics" '[.[0].logs[] | select(.category == "ActivityRuns" and .enabled == true)] | length' "0")
            if [[ "$activity_count" -gt 0 ]]; then
                activity_logging_enabled="true"
            fi
            
            trigger_count=$(safe_jq "$diagnostics" '[.[0].logs[] | select(.category == "TriggerRuns" and .enabled == true)] | length' "0")
            if [[ "$trigger_count" -gt 0 ]]; then
                trigger_logging_enabled="true"
            fi
        fi
    fi
    rm -f diag_err.log 2>/dev/null || true

    # Get pipelines with error handling
    echo "Getting pipelines for $df_name..."
    pipelines="[]"
    if temp_pipelines=$(az datafactory pipeline list --factory-name "$df_name" --resource-group "$df_rg" --subscription "$subscription_id" -o json 2>/dev/null); then
        if validate_json "$temp_pipelines"; then
            pipelines="$temp_pipelines"
        fi
    fi

    # Get triggers with error handling
    echo "Getting triggers for $df_name..."
    triggers="[]"
    if temp_triggers=$(az datafactory trigger list --factory-name "$df_name" --resource-group "$df_rg" --subscription "$subscription_id" -o json 2>/dev/null); then
        if validate_json "$temp_triggers"; then
            triggers="$temp_triggers"
        fi
    fi

    # Get linked services with error handling
    echo "Getting linked services for $df_name..."
    linked_services="[]"
    if temp_linked=$(az datafactory linked-service list --factory-name "$df_name" --resource-group "$df_rg" --subscription "$subscription_id" -o json 2>/dev/null); then
        if validate_json "$temp_linked"; then
            linked_services="$temp_linked"
        fi
    fi

    # Get datasets with error handling
    echo "Getting datasets for $df_name..."
    datasets="[]"
    if temp_datasets=$(az datafactory dataset list --factory-name "$df_name" --resource-group "$df_rg" --subscription "$subscription_id" -o json 2>/dev/null); then
        if validate_json "$temp_datasets"; then
            datasets="$temp_datasets"
        fi
    fi

    # Add to JSON output with error handling
    if ! adf_details_json=$(echo "$adf_details_json" | jq \
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
        }]' 2>/dev/null); then
        echo "WARNING: Failed to add Data Factory $df_name to output JSON"
    fi
done < <(echo "$datafactories" | jq -c '.[]' 2>/dev/null || echo "")

# Write output to file
echo "Final JSON contents:"
if validate_json "$adf_details_json"; then
    echo "$adf_details_json" | jq . 2>/dev/null || echo "$adf_details_json"
else
    echo "Warning: Final JSON is invalid, using fallback"
    adf_details_json='{"data_factories": []}'
fi
echo "$adf_details_json" > "$output_file"
echo "Azure Data Factory details check completed. Results saved to $output_file"
