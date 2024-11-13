#!/bin/bash

# ENV:
# AZ_USERNAME
# AZ_SECRET_VALUE
# AZ_SUBSCRIPTION
# AZ_TENANT
# APPSERVICE
# AZ_RESOURCE_GROUP

# Check if AZURE_RESOURCE_SUBSCRIPTION_ID is set, otherwise get the current subscription ID
if [ -z "$AZURE_RESOURCE_SUBSCRIPTION_ID" ]; then
    subscription=$(az account show --query "id" -o tsv)
    echo "AZURE_RESOURCE_SUBSCRIPTION_ID is not set. Using current subscription ID: $subscription"
else
    subscription="$AZURE_RESOURCE_SUBSCRIPTION_ID"
    echo "Using specified subscription ID: $subscription"
fi

# Set the subscription to the determined ID
echo "Switching to subscription ID: $subscription"
az account set --subscription "$subscription" || { echo "Failed to set subscription."; exit 1; }


WEBAPP_TYPE="Microsoft.Web/sites"
HEALTH_METRIC="HealthCheckStatus"
METRIC_TOP=100
ALLOWED_MIN=95

# Get the health status of the App Service web app
health_status=$(az monitor metrics list --resource $APPSERVICE --resource-group $AZ_RESOURCE_GROUP  --resource-type Microsoft.Web/sites --metric "HealthCheckStatus" --interval 5m --aggregation minimum --top $METRIC_TOP)
healthy=0
# Loop through the metric time series
for metric in $(echo "$health_status" | jq -r '.value[].timeseries[].data[].minimum'); do
    # Check if the metric value is below the allowed min
    if [[ $metric -lt $ALLOWED_MIN ]]; then
        healthy=1
        break
    fi
done
if [ $healthy -eq 1 ]; then
    echo "Error: The App Service $APPSERVICE has recent health check failures"
    echo "Health metric timeseries contains values below the allowed minimum: $ALLOWED_MIN"
    echo ""
    echo -E "$health_status"
    exit 1
else
    echo "The App Service web app is healthy"
    exit 0
fi
