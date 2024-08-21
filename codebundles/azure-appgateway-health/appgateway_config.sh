#!/bin/bash

# ENV:
# AZ_USERNAME
# AZ_SECRET_VALUE
# AZ_TENANT
# AZ_SUBSCRIPTION
# AZ_RESOURCE_GROUP
# APPGATEWAY


# Log in to Azure CLI
az login --service-principal --username $AZ_USERNAME --password $AZ_SECRET_VALUE --tenant $AZ_TENANT > /dev/null
# Set the subscription
az account set --subscription $AZ_SUBSCRIPTION

config=$(az network application-gateway show -n $APPGATEWAY --resource-group $AZ_RESOURCE_GROUP)
echo "$config"

# TODO: do config checks