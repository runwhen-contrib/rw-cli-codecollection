#!/bin/bash

# ENV:
# AZ_USERNAME
# AZ_SECRET_VALUE
# AZ_SUBSCRIPTION
# AZ_TENANT
# ADF
# AZ_RESOURCE_GROUP

# # Log in to Azure CLI
# az login --service-principal --username $AZ_USERNAME --password $AZ_SECRET_VALUE --tenant $AZ_TENANT > /dev/null

# # Set the subscription
# az account set --subscription $AZ_SUBSCRIPTION

echo "Azure Data Factory $ADF activity logs (recent):"
# Get the activity logs of the vm scaled set
resource_id=$(az datafactory show --name $ADF --resource-group $AZ_RESOURCE_GROUP --subscription $AZ_SUBSCRIPTION --query "id")
az monitor activity-log list --resource-id $resource_id --resource-group $AZ_RESOURCE_GROUP --output table

# TODO: hook into various activities to create suggestions
# TODO: add general raise issue for found critical