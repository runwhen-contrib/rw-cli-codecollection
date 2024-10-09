#!/bin/bash

# ENV:
# AZ_USERNAME
# AZ_SECRET_VALUE
# AZ_SUBSCRIPTION
# AZ_TENANT
# VMSCALEDSET
# AZ_RESOURCE_GROUP

# # Log in to Azure CLI
# az login --service-principal --username $AZ_USERNAME --password $AZ_SECRET_VALUE --tenant $AZ_TENANT > /dev/null

# # Set the subscription
# az account set --subscription $AZ_SUBSCRIPTION

echo "Azure API Management $API activity logs (recent):"
# Get the activity logs of the vm scaled set
resource_id=$(az apim show --name $API --resource-group $AZ_RESOURCE_GROUP --subscription $AZ_SUBSCRIPTION --query "id")
az monitor activity-log list --resource-id $resource_id --resource-group $AZ_RESOURCE_GROUP --output table

# TODO: hook into various activities to create suggestions