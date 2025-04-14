#!/bin/bash

# Check environment variables
if [[ -z "$AZ_RESOURCE_GROUP" || -z "$FUNCTION_APP_NAME" ]]; then
    echo "Error: Please ensure AZ_RESOURCE_GROUP and FUNCTION_APP_NAME environment variables are set."
    exit 1
fi

# Retrieve subscription from current Azure CLI context
subscription=$(az account show --query "id" -o tsv)

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

    # Check if the provider is still not registered after waiting
    if [[ "$registrationState" != "Registered" ]]; then
        echo "Error: Microsoft.ResourceHealth provider could not be registered."
        exit 1
    fi
else
    echo "Microsoft.ResourceHealth provider is already registered."
fi

# Perform the REST API call to get the resource health status for the Function App
echo "Retrieving health status for Azure Function App '$FUNCTION_APP_NAME'..."
healthUrl="https://management.azure.com/subscriptions/$subscription/resourceGroups/$AZ_RESOURCE_GROUP/providers/Microsoft.Web/sites/$FUNCTION_APP_NAME/providers/Microsoft.ResourceHealth/availabilityStatuses/current?api-version=2023-07-01-preview"

az rest --method GET --url "$healthUrl" > "function_app_health.json"

if [[ $? -eq 0 ]]; then
    echo "Health status retrieved successfully. Output saved to function_app_health.json"
    cat "function_app_health.json"
else
    echo "Error: Failed to retrieve health status for Azure Function App."
    exit 1
fi
