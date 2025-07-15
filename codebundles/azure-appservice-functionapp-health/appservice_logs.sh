#!/bin/bash

# ENV:
#   FUNCTION_APP_NAME  - Name of the Azure Function App
#   AZ_RESOURCE_GROUP  - Resource group containing the Function App
#   AZURE_RESOURCE_SUBSCRIPTION_ID - (Optional) Subscription ID (defaults to current subscription)

# Use subscription ID from environment variable
subscription_id="$AZURE_RESOURCE_SUBSCRIPTION_ID"
echo "Using subscription ID: $subscription_id"

# Set the subscription to the determined ID with timeout
if ! timeout 10s az account set --subscription "$subscription_id" 2>/dev/null; then
    echo "Failed to set subscription within timeout."
    exit 1
fi

# Name of the zip file to store logs
LOG_PATH="_rw_logs_${FUNCTION_APP_NAME}.zip"

echo "Downloading logs for Azure Function App: $FUNCTION_APP_NAME..."

# Check if function app exists and is running first
echo "Checking Function App status..."
if ! function_app_status=$(timeout 15s az functionapp show --name "$FUNCTION_APP_NAME" --resource-group "$AZ_RESOURCE_GROUP" --query "state" -o tsv 2>/dev/null); then
    echo "Error: Could not retrieve Function App status. Function App may not exist or access may be restricted."
    exit 1
fi

if [[ "$function_app_status" != "Running" ]]; then
    echo "Warning: Function App is not running (status: $function_app_status). Log download may fail."
fi

# Download logs with timeout
echo "Attempting to download logs (timeout: 45 seconds)..."
if timeout 45s az webapp log download \
  --name "$FUNCTION_APP_NAME" \
  --resource-group "$AZ_RESOURCE_GROUP" \
  --subscription "$subscription_id" \
  --log-file "$LOG_PATH" 2>/dev/null; then
    
    # Check if the log file was actually created and has content
    if [[ -f "$LOG_PATH" && -s "$LOG_PATH" ]]; then
        echo "✅ Log files downloaded successfully"
        
        # Unzip and display a summary of the contents with timeout
        echo "Log files found:"
        if timeout 10s unzip -l "$LOG_PATH" 2>/dev/null | head -10; then
            echo ""
            echo "Recent log entries (last 20 lines):"
            if timeout 15s unzip -qq -c "$LOG_PATH" 2>/dev/null | grep -E "(ERROR|WARN|Exception|Failed)" | tail -20; then
                echo ""
            else
                echo "No recent errors found in logs."
            fi
        else
            echo "Warning: Could not read log file contents within timeout"
        fi
        
        # Clean up
        rm -f "$LOG_PATH"
    else
        echo "Warning: Log file was not created or is empty"
    fi
else
    echo "Warning: Unable to download logs within timeout period."
    echo "This could be due to:"
    echo "  - Function App is stopped"
    echo "  - Logging is disabled"
    echo "  - Network connectivity issues"
    echo "  - Insufficient permissions"
    
    # Try to get log stream as fallback
    echo ""
    echo "Attempting to get recent log stream (timeout: 30 seconds)..."
    if timeout 30s az webapp log tail \
      --name "$FUNCTION_APP_NAME" \
      --resource-group "$AZ_RESOURCE_GROUP" \
      --subscription "$subscription_id" \
      --provider docker 2>/dev/null | head -50; then
        echo ""
        echo "✅ Retrieved recent log stream"
    else
        echo "Warning: Could not retrieve log stream either"
    fi
fi

echo ""
echo "Log retrieval completed."
