#!/bin/bash

# Configure Azure CLI to explicitly allow or disallow preview extensions
az config set extension.dynamic_install_allow_preview=true
# Check and install datafactory extension if needed
echo "Checking for datafactory extension..."
if ! az extension show --name datafactory > /dev/null; then
    echo "Installing datafactory extension..."
    az extension add --name datafactory || { echo "Failed to install datafactory extension."; exit 1; }
fi

HEALTH_OUTPUT="datafactory_health.json"
echo "[]" > "$HEALTH_OUTPUT"

# Get or set subscription ID
if [ -z "$AZURE_SUBSCRIPTION_ID" ]; then
    subscription=$(az account show --query "id" -o tsv)
    echo "AZURE_SUBSCRIPTION_ID is not set. Using current subscription ID: $subscription"
else
    subscription="$AZURE_SUBSCRIPTION_ID"
    echo "Using specified subscription ID: $subscription"
fi

# Set the subscription ID
echo "Switching to subscription ID: $subscription"
az account set --subscription "$subscription" || { echo "Failed to set subscription."; exit 1; }

# Check if Microsoft.ResourceHealth provider is registered
echo "Checking registration status of Microsoft.ResourceHealth provider..."
registrationState=$(az provider show --namespace Microsoft.ResourceHealth --query "registrationState" -o tsv)

if [[ "$registrationState" != "Registered" ]]; then
    echo "Registering Microsoft.ResourceHealth provider..."
    az provider register --namespace Microsoft.ResourceHealth

    # Wait for registration
    echo "Waiting for Microsoft.ResourceHealth provider to register..."
    for i in {1..10}; do
        registrationState=$(az provider show --namespace Microsoft.ResourceHealth --query "registrationState" -o tsv)
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
        echo "Error: Microsoft.ResourceHealth provider could not be registered."
        exit 1
    fi
else
    echo "Microsoft.ResourceHealth provider is already registered."
fi

# Check required environment variables
if [ -z "$AZURE_RESOURCE_GROUP" ] || [ -z "$AZURE_SUBSCRIPTION_NAME" ]; then
    echo "Error: AZURE_RESOURCE_GROUP and AZURE_SUBSCRIPTION_NAME environment variables must be set."
    exit 1
fi

# Get list of Data Factories in the resource group
echo "Retrieving Data Factories in resource group..."
echo "az datafactory list -g "$AZURE_RESOURCE_GROUP" --subscription "$subscription" --query "[].name" -o tsv"
datafactories_json=$(az datafactory list -g "$AZURE_RESOURCE_GROUP" --subscription "$subscription" --query "[].name" -o tsv) || { echo "Failed to list Data Factories."; exit 1; }

# Process each Data Factory
for df_name in $datafactories_json; do
    echo "Retrieving health status for Data Factory: $df_name..."
    # Get health status for current Data Factory
    health_status=$(az rest --method get \
        --url "https://management.azure.com/subscriptions/$subscription/resourceGroups/$AZURE_RESOURCE_GROUP/providers/Microsoft.DataFactory/factories/$df_name/providers/Microsoft.ResourceHealth/availabilityStatuses/current?api-version=2023-07-01-preview" \
        -o json) || { echo "Failed to retrieve health status for $df_name."; continue; }
    
    # Add the health status to the array in the JSON file
    jq --argjson health "$health_status" '. += [$health]' "$HEALTH_OUTPUT" > temp.json && mv temp.json "$HEALTH_OUTPUT"
done

# Output results
echo "Health status retrieved and saved to: $HEALTH_OUTPUT"