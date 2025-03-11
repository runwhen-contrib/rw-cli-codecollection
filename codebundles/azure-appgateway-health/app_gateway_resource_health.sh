#!/bin/bash


HEALTH_OUTPUT="app_gateway_health.json"
echo "[]" > "$HEALTH_OUTPUT"

# Get or set subscription ID
if [ -z "$AZURE_RESOURCE_SUBSCRIPTION_ID" ]; then
    subscription=$(az account show --query "id" -o tsv)
    echo "AZURE_RESOURCE_SUBSCRIPTION_ID is not set. Using current subscription ID: $subscription"
else
    subscription="$AZURE_RESOURCE_SUBSCRIPTION_ID"
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
if [ -z "$AZ_RESOURCE_GROUP" ] || [ -z "$APP_GATEWAY_NAME" ]; then
    echo "Error: AZ_RESOURCE_GROUP and APP_GATEWAY_NAME environment variables must be set."
    exit 1
fi

# Retrieve health status for the Application Gateway
echo "Retrieving health status for Application Gateway: $APP_GATEWAY_NAME..."
az rest --method get \
    --url "https://management.azure.com/subscriptions/$subscription/resourceGroups/$AZ_RESOURCE_GROUP/providers/Microsoft.Network/applicationGateways/$APP_GATEWAY_NAME/providers/Microsoft.ResourceHealth/availabilityStatuses/current?api-version=2023-07-01-preview" \
    > "$HEALTH_OUTPUT" || { echo "Failed to retrieve health status."; exit 1; }

# Output results
echo "Health status retrieved and saved to: $HEALTH_OUTPUT"
cat "$HEALTH_OUTPUT"
