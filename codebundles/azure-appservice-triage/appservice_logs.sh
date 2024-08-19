#!/bin/bash

# ENV:
# AZ_USERNAME
# AZ_SECRET_VALUE
# AZ_SUBSCRIPTION
# AZ_TENANT
# APPSERVICE
# AZ_RESOURCE_GROUP

LOG_PATH="/tmp/_rw_logs_$APPSERVICE.zip"
NUM_LINES=300

# Log in to Azure CLI
az login --service-principal --username $AZ_USERNAME --password $AZ_SECRET_VALUE --tenant $AZ_TENANT > /dev/null
# Set the subscription
az account set --subscription $AZ_SUBSCRIPTION

az webapp log download --name $APPSERVICE --resource-group $AZ_RESOURCE_GROUP --subscription $AZ_SUBSCRIPTION --log-file $LOG_PATH
log_contents=$(unzip -qq -c $LOG_PATH)

echo "Azure App Service $APPSERVICE logs:"
echo ""
echo ""
echo -e "$log_contents" | tail -n $NUM_LINES