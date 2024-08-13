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
az account set --subscription $SUBSCRIPTION_ID

# Fetch the events of the app service webapp
events=$(az webapp log deployment list --name $APPSERVICE --resource-group $AZ_RESOURCE_GROUP --query "[?status=='Failed'].{id:id, message:message}" --output json)

# Check for errors in the events
if [[ -n $events ]]; then
    echo "Errors found in app service events:"
    echo $events
    exit 1
fi

exit 0