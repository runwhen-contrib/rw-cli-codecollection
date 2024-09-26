#!/bin/bash

# ENV:
# AZ_USERNAME
# AZ_SECRET_VALUE
# AZ_SUBSCRIPTION
# AZ_TENANT
# APPSERVICE
# AZ_RESOURCE_GROUP

WEBAPP_TYPE="Microsoft.Web/sites"

# # Log in to Azure CLI
# az login --service-principal --username $AZ_USERNAME --password $AZ_SECRET_VALUE --tenant $AZ_TENANT > /dev/null

# # Set the subscription
# az account set --subscription $AZ_SUBSCRIPTION

echo "Azure App Service $APPSERVICE activity logs (recent):"
# Get the activity logs of the web app
resource_id=$(az webapp show --name $APPSERVICE --resource-group $AZ_RESOURCE_GROUP --subscription $AZ_SUBSCRIPTION --query "id")
az monitor activity-log list --resource-id $resource_id --resource-group $AZ_RESOURCE_GROUP --output table

# TODO: hook into various activities to create suggestions