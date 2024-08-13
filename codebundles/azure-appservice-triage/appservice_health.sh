#!/bin/bash

# ENV:
# AZ_USERNAME
# AZ_SECRET_VALUE
# AZ_TENANT
# APPSERVICE
# AZ_RESOURCE_GROUP

# Log in to Azure CLI
az login --service-principal --username $AZ_USERNAME --password $AZ_SECRET_VALUE --tenant $AZ_TENANT

# Set the subscription
# az account set --subscription $SUBSCRIPTION_ID
# Get the health status of the App Service web app
health_status=$(az monitor app-insights component show-health --app $APPSERVICE --resource-group $AZ_RESOURCE_GROUP --query 'healthStatus' -o tsv)

# Print the health status
echo "Health Status: $health_status"

# Check if the health status is not healthy
if [[ "$health_status" != "Healthy" ]]; then
    echo "Error: App Service is not healthy"
    exit 1
fi
exit 0
