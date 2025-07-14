#!/bin/bash

# ENV:
#   FUNCTION_APP_NAME  - Name of the Azure Function App
#   AZ_RESOURCE_GROUP  - Resource group containing the Function App
#   AZURE_RESOURCE_SUBSCRIPTION_ID - (Optional) Subscription ID (defaults to current subscription)

# Get or set subscription ID
if [[ -z "${AZURE_RESOURCE_SUBSCRIPTION_ID:-}" ]]; then
    subscription_id=$(az account show --query "id" -o tsv)
    echo "Using current subscription ID: $subscription_id"
else
    subscription_id="$AZURE_RESOURCE_SUBSCRIPTION_ID"
    echo "Using specified subscription ID: $subscription_id"
fi

# Set the subscription to the determined ID
az account set --subscription "$subscription_id" || { echo "Failed to set subscription."; exit 1; }

# Name of the zip file to store logs
LOG_PATH="_rw_logs_${FUNCTION_APP_NAME}.zip"

echo "Downloading logs for Azure Function App: $FUNCTION_APP_NAME..."

# Download logs
if az webapp log download \
  --name "$FUNCTION_APP_NAME" \
  --resource-group "$AZ_RESOURCE_GROUP" \
  --subscription "$subscription_id" \
  --log-file "$LOG_PATH" 2>/dev/null; then
    
    # Unzip and display a summary of the contents
    echo "Log files found:"
    unzip -l "$LOG_PATH" | head -10
    
    # Show only the last 20 lines of recent logs (if any)
    echo ""
    echo "Recent log entries (last 20 lines):"
    unzip -qq -c "$LOG_PATH" | grep -E "(ERROR|WARN|Exception|Failed)" | tail -20 || echo "No recent errors found in logs."
    
    # Clean up
    rm -f "$LOG_PATH"
else
    echo "Warning: Unable to download logs. Function App may be stopped or logging disabled."
fi
