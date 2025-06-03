#!/bin/bash

# ENV:
#   FUNCTION_APP_NAME  - Name of the Azure Function App
#   AZ_RESOURCE_GROUP  - Resource group containing the Function App
#   AZURE_RESOURCE_SUBSCRIPTION_ID - (Optional) Subscription ID (defaults to current subscription)

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

# Name of the zip file to store logs
LOG_PATH="_rw_logs_${FUNCTION_APP_NAME}.zip"

echo "Downloading logs for Azure Function App: $FUNCTION_APP_NAME ..."

# Even though it's a Function App, we can still use 'az webapp log download'
# because Function Apps and Web Apps share the Microsoft.Web/sites resource type.
az webapp log download \
  --name "$FUNCTION_APP_NAME" \
  --resource-group "$AZ_RESOURCE_GROUP" \
  --subscription "$subscription_id" \
  --log-file "$LOG_PATH"

# Unzip and display the contents
log_contents=$(unzip -qq -c "$LOG_PATH")

echo "Azure Function App '$FUNCTION_APP_NAME' logs:"
echo ""
echo "$log_contents"
