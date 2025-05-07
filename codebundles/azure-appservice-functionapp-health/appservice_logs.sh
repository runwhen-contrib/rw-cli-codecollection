#!/bin/bash

# ENV:
#   AZ_USERNAME (optional if your Azure CLI is already authenticated)
#   AZ_SECRET_VALUE (optional)
#   AZ_SUBSCRIPTION (optional if your Azure CLI context is correct)
#   AZ_TENANT (optional)
#   FUNCTION_APP_NAME  - Name of the Azure Function App
#   AZ_RESOURCE_GROUP  - Resource group containing the Function App

# Name of the zip file to store logs
LOG_PATH="_rw_logs_${FUNCTION_APP_NAME}.zip"

# Retrieve the current subscription ID (or use AZ_SUBSCRIPTION if you prefer)
subscription_id=$(az account show --query "id" -o tsv)

# If needed, you can explicitly set the subscription (uncomment):
# az account set --subscription "$AZ_SUBSCRIPTION"

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
