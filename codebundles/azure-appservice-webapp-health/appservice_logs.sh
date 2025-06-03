#!/bin/bash

# ENV:
# APP_SERVICE_NAME
# AZ_RESOURCE_GROUP
# AZURE_RESOURCE_SUBSCRIPTION_ID (Optional, defaults to current subscription)

LOG_PATH="app_service_logs.zip"

# Get or set subscription ID
if [[ -z "${AZURE_RESOURCE_SUBSCRIPTION_ID:-}" ]]; then
    subscription_id=$(az account show --query "id" -o tsv)
    echo "AZURE_RESOURCE_SUBSCRIPTION_ID is not set. Using current subscription ID: $subscription_id"
else
    subscription_id="$AZURE_RESOURCE_SUBSCRIPTION_ID"
    echo "Using specified subscription ID: $subscription_id"
fi

# Set the subscription to the determined ID
echo "Switching to subscription ID: $subscription_id"
az account set --subscription "$subscription_id" || { echo "Failed to set subscription."; exit 1; }

az webapp log download --name $APP_SERVICE_NAME --resource-group $AZ_RESOURCE_GROUP --subscription $subscription_id --log-file $LOG_PATH
log_contents=$(unzip -qq -c $LOG_PATH)

echo "Azure App Service $APP_SERVICE_NAME logs:"
echo ""
echo ""
echo -e "$log_contents"