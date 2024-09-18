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

echo "Azure VM Scaled Set $VMSCALEDSET activity logs (recent):"
# Get the activity logs of the web app
az monitor activity-log list --resource-group $AZ_RESOURCE_GROUP --query "[].{level: level, description: description, time: eventTimestamp, resourceId: resourceId}" --output table

# TODO: hook into various activities to create suggestions