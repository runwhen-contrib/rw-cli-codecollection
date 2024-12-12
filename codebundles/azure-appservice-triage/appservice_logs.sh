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

subscription_id=$(az account show --query "id" -o tsv)

# # Set the subscription
az account set --subscription $subscription_id

az webapp log download --name $APPSERVICE --resource-group $AZ_RESOURCE_GROUP --subscription $subscription_id --log-file $LOG_PATH
log_contents=$(unzip -qq -c $LOG_PATH)

echo "Azure App Service $APPSERVICE logs:"
echo ""
echo ""
echo -e "$log_contents" | tail -n $NUM_LINES