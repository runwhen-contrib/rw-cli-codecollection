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

HEALTH_OUTPUT="asp_health.json"
echo "[]" > "$HEALTH_OUTPUT"

# Get or set subscription ID
if [ -z "$AZURE_SUBSCRIPTION_ID" ]; then
    subscription=$(az account show --query "id" -o tsv)
    echo "AZURE_SUBSCRIPTION_ID is not set. Using current subscription ID: $subscription"
else
    subscription="$AZURE_SUBSCRIPTION_ID"
    echo "Using specified subscription ID: $subscription"
fi

# Check if Microsoft.ResourceHealth provider is registered
echo "Checking registration status of Microsoft.ResourceHealth provider..."
registrationState=$(az provider show --namespace Microsoft.ResourceHealth --subscription "$subscription" --query "registrationState" -o tsv)

if [[ "$registrationState" != "Registered" ]]; then
    echo "Registering Microsoft.ResourceHealth provider..."
    az provider register --namespace Microsoft.ResourceHealth --subscription "$subscription"

    # Wait for registration
    echo "Waiting for Microsoft.ResourceHealth provider to register..."
    for i in {1..10}; do
        registrationState=$(az provider show --namespace Microsoft.ResourceHealth --subscription "$subscription" --query "registrationState" -o tsv)
        if [[ "$registrationState" == "Registered" ]]; then
            echo "Microsoft.ResourceHealth provider registered successfully."
            break
        else
            echo "Current registration state: $registrationState. Retrying in 10 seconds..."
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
if [ -z "$AZURE_RESOURCE_GROUP" ]; then
        timestamp=$(date -u +"%Y-%m-%dT%H:%M:%S.%3NZ")

    # Extract timestamp from log context


    log_timestamp=$(extract_log_timestamp "$0")


    echo "Error: AZURE_RESOURCE_GROUP environment variable must be set. (detected at $log_timestamp)"
    exit 1
fi

# Validate resource group exists in the current subscription
echo "Validating resource group '$AZURE_RESOURCE_GROUP' exists in subscription '$subscription'..."
resource_group_exists=$(az group show --name "$AZURE_RESOURCE_GROUP" --subscription "$subscription" --query "name" -o tsv 2>/dev/null)

if [ -z "$resource_group_exists" ]; then
    echo "ERROR: Resource group '$AZURE_RESOURCE_GROUP' was not found in subscription '$subscription'."
    echo ""
    echo "Available resource groups in subscription '$subscription':"
    az group list --subscription "$subscription" --query "[].name" -o tsv | sort
    echo ""
    echo "Please verify:"
    echo "1. The resource group name is correct"
    echo "2. You have access to the resource group"
    echo "3. You're using the correct subscription"
    echo "4. The resource group exists in this subscription"
    exit 1
fi

echo "Resource group '$AZURE_RESOURCE_GROUP' validated successfully."

# Define provider path for App Service Plans
provider_path="Microsoft.Web/serverfarms"
display_name="Azure App Service Plan"

echo "Processing resource type: app-service-plan ($display_name)"

# Get list of App Service Plans in the resource group
instances=$(az appservice plan list -g "$AZURE_RESOURCE_GROUP" --subscription "$subscription" --query "[].name" -o tsv)

# Process each App Service Plan
for instance in $instances; do
    echo "Retrieving health status for $display_name: $instance..."
    
    # Get health status for current instance
    health_status=$(az rest --method get \
        --url "https://management.azure.com/subscriptions/$subscription/resourceGroups/$AZURE_RESOURCE_GROUP/providers/$provider_path/$instance/providers/Microsoft.ResourceHealth/availabilityStatuses/current?api-version=2023-07-01-preview" \
        -o json 2>/dev/null)
    
    # Check if health status retrieval was successful
    if [ $? -eq 0 ]; then
        # Add resource type and name to the health status
        health_status=$(echo "$health_status" | jq --arg type "app-service-plan" --arg name "$instance" --arg display "$display_name" '. + {resourceType: $type, resourceName: $name, displayName: $display}')
        
        # Add the health status to the array in the JSON file
        jq --argjson health "$health_status" '. += [$health]' "$HEALTH_OUTPUT" > temp.json && mv temp.json "$HEALTH_OUTPUT"
        if ! jq empty "$HEALTH_OUTPUT" 2>/dev/null; then
            echo "Invalid JSON detected in $HEALTH_OUTPUT"
            exit 1
        fi
    else
        echo "Failed to retrieve health status for $instance ($provider_path/$instance). This might be due to unsupported resource type or other API limitations."
    fi
done

# Output results
echo "App Service Plan health status retrieved and saved to: $HEALTH_OUTPUT"
cat "$HEALTH_OUTPUT"
