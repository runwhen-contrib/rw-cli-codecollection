#!/bin/bash

# ENV:
# AZ_USERNAME
# AZ_SECRET_VALUE
# AZ_SUBSCRIPTION
# AZ_TENANT
# VMSCALEDSET
# AZ_RESOURCE_GROUP

# Log in to Azure CLI
az login --service-principal --username $AZ_USERNAME --password $AZ_SECRET_VALUE --tenant $AZ_TENANT > /dev/null
# Set the subscription
az account set --subscription $AZ_SUBSCRIPTION

az vmss show --name $VMSCALEDSET --resource-group $AZ_RESOURCE_GROUP --subscription $AZ_SUBSCRIPTION

# TODO: perform config checks