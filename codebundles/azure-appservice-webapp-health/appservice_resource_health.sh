#!/bin/bash

# Get or set subscription ID
if [[ -z "${AZURE_RESOURCE_SUBSCRIPTION_ID:-}" ]]; then
    subscription=$(az account show --query "id" -o tsv)
    echo "AZURE_RESOURCE_SUBSCRIPTION_ID is not set. Using current subscription ID: $subscription"
else
    subscription="$AZURE_RESOURCE_SUBSCRIPTION_ID"
    echo "Using specified subscription ID: $subscription"
fi

# Set the subscription to the determined ID
echo "Switching to subscription ID: $subscription"
az account set --subscription "$subscription" || { echo "Failed to set subscription."; exit 1; }

# Check if Microsoft.ResourceHealth provider is already registered
echo "Checking registration status of Microsoft.ResourceHealth provider..."
registrationState=$(az provider show --namespace Microsoft.ResourceHealth --query "registrationState" -o tsv)

if [[ "$registrationState" != "Registered" ]]; then
    echo "Registering Microsoft.ResourceHealth provider..."
    az provider register --namespace Microsoft.ResourceHealth

    # Wait for the provider to be registered
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

    # Check if the provider is not registered after waiting
    if [[ "$registrationState" != "Registered" ]]; then
        echo "Error: Microsoft.ResourceHealth provider could not be registered."
        exit 1
    fi
else
    echo "Microsoft.ResourceHealth provider is already registered."
fi

# Perform the REST API call to get the resource health status
echo "Retrieving health status for Azure App Service..."
healthUrl="https://management.azure.com/subscriptions/$subscription/resourceGroups/$AZ_RESOURCE_GROUP/providers/Microsoft.Web/sites/$APP_SERVICE_NAME/providers/Microsoft.ResourceHealth/availabilityStatuses/current?api-version=2023-07-01-preview"

az rest --method get --url "$healthUrl" > "app_service_health.json"

if [[ $? -eq 0 ]]; then
    echo "Health status retrieved successfully. Output saved to app_service_health.json"
    cat "app_service_health.json"
else
    echo "Error: Failed to retrieve health status for Azure App Service."
    exit 1
fi
