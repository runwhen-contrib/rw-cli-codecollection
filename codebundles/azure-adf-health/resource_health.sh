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

HEALTH_OUTPUT="datafactory_health.json"
echo "[]" > "$HEALTH_OUTPUT"

# Get or set subscription ID
if [[ -z "${AZURE_RESOURCE_SUBSCRIPTION_ID:-}" ]]; then
    subscription=$(az account show --query "id" -o tsv 2>/dev/null || echo "")
    if [[ -z "$subscription" ]]; then
        echo "ERROR: Could not determine current subscription ID and AZURE_RESOURCE_SUBSCRIPTION_ID is not set."
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
    exit 1
fi

# Check if Microsoft.ResourceHealth provider is registered
echo "Checking registration status of Microsoft.ResourceHealth provider..."
if ! registrationState=$(az provider show --namespace Microsoft.ResourceHealth --query "registrationState" -o tsv 2>/dev/null); then
    echo "ERROR: Failed to check Microsoft.ResourceHealth provider status"
    exit 1
fi

if [[ "$registrationState" != "Registered" ]]; then
    echo "Registering Microsoft.ResourceHealth provider..."
    if ! az provider register --namespace Microsoft.ResourceHealth 2>/dev/null; then
        echo "ERROR: Failed to register Microsoft.ResourceHealth provider"
        exit 1
    fi

    # Wait for registration
    echo "Waiting for Microsoft.ResourceHealth provider to register..."
    for i in {1..10}; do
        if registrationState=$(az provider show --namespace Microsoft.ResourceHealth --query "registrationState" -o tsv 2>/dev/null); then
            if [[ "$registrationState" == "Registered" ]]; then
                echo "Microsoft.ResourceHealth provider registered successfully."
                break
            else
                echo "Current registration state: $registrationState. Retrying in 10 seconds..."
                sleep 10
            fi
        else
            echo "Failed to check registration state. Retrying in 10 seconds..."
            sleep 10
        fi
    done

    # Exit if registration fails
    if [[ "$registrationState" != "Registered" ]]; then
        timestamp=$(date -u +"%Y-%m-%dT%H:%M:%S.%3NZ")

        # Extract timestamp from log context


        log_timestamp=$(extract_log_timestamp "$0")


        echo "Error: Microsoft.ResourceHealth provider could not be registered. (detected at $log_timestamp)"
        exit 1
    fi
else
    echo "Microsoft.ResourceHealth provider is already registered."
fi

# Check required environment variables
if [ -z "${AZURE_RESOURCE_GROUP:-}" ]; then
        timestamp=$(date -u +"%Y-%m-%dT%H:%M:%S.%3NZ")

    # Extract timestamp from log context


    log_timestamp=$(extract_log_timestamp "$0")


    echo "Error: AZURE_RESOURCE_GROUP environment variable must be set. (detected at $log_timestamp)"
    exit 1
fi

# Get list of Data Factories in the resource group
echo "Retrieving Data Factories in resource group..."
echo "az datafactory list -g \"$AZURE_RESOURCE_GROUP\" --subscription \"$subscription\" --query \"[].name\" -o tsv"
if ! datafactories_json=$(az datafactory list -g "$AZURE_RESOURCE_GROUP" --subscription "$subscription" --query "[].name" -o tsv 2>/dev/null); then
    echo "ERROR: Failed to list Data Factories."
    exit 1
fi

if [[ -z "$datafactories_json" ]]; then
    echo "No Data Factories found in resource group $AZURE_RESOURCE_GROUP"
    exit 0
fi

# Process each Data Factory
while IFS= read -r df_name; do
    if [[ -z "$df_name" ]]; then
        continue
    fi
    
    echo "Retrieving health status for Data Factory: $df_name..."
    # Get health status for current Data Factory
    if health_status=$(az rest --method get \
        --url "https://management.azure.com/subscriptions/$subscription/resourceGroups/$AZURE_RESOURCE_GROUP/providers/Microsoft.DataFactory/factories/$df_name/providers/Microsoft.ResourceHealth/availabilityStatuses/current?api-version=2023-07-01-preview" \
        -o json 2>/dev/null); then
        
        if validate_json "$health_status"; then
            # Add the health status to the array in the JSON file
            if ! jq --argjson health "$health_status" '. += [$health]' "$HEALTH_OUTPUT" > temp.json 2>/dev/null; then
                echo "WARNING: Failed to process health status JSON for $df_name"
                continue
            fi
            mv temp.json "$HEALTH_OUTPUT" 2>/dev/null || {
                echo "WARNING: Failed to update health output file"
                rm -f temp.json
            }
        else
            echo "WARNING: Invalid JSON response for health status of $df_name"
        fi
    else
        echo "WARNING: Failed to retrieve health status for $df_name."
    fi
done <<< "$datafactories_json"

# Output results
echo "Health status retrieved and saved to: $HEALTH_OUTPUT"