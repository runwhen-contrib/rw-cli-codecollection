#!/bin/bash

# ENV:
# AZ_USERNAME
# AZ_SECRET_VALUE
# AZ_SUBSCRIPTION
# AZ_TENANT
# APPSERVICE
# AZ_RESOURCE_GROUP

WEBAPP_TYPE="Microsoft.Web/sites"
HEALTH_METRIC="HealthCheckStatus"
METRIC_TOP=100
ALLOWED_MIN=95

# # Log in to Azure CLI
# az login --service-principal --username $AZ_USERNAME --password $AZ_SECRET_VALUE --tenant $AZ_TENANT > /dev/null
# # Set the subscription
# az account set --subscription $AZ_SUBSCRIPTION

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
