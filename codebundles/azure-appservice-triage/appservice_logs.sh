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


# Get the logs of the Azure App Service
az webapp log tail --name $APPSERVICE --resource-group $AZ_RESOURCE_GROUP