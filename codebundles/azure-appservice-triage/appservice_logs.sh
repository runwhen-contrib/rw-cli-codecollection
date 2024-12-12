#!/bin/bash

# ENV:
# AZ_USERNAME
# AZ_SECRET_VALUE
# AZ_SUBSCRIPTION
# AZ_TENANT
# APP_SERVICE_NAME
# AZ_RESOURCE_GROUP

LOG_PATH="/$OUTPUT_DIR/_rw_logs_$APP_SERVICE_NAME.zip"
NUM_LINES=300

subscription_id=$(az account show --query "id" -o tsv)

# # Set the subscription
az account set --subscription $subscription_id

az webapp log download --name $APP_SERVICE_NAME --resource-group $AZ_RESOURCE_GROUP --subscription $subscription_id --log-file $LOG_PATH
log_contents=$(unzip -qq -c $LOG_PATH)

echo "Azure App Service $APP_SERVICE_NAME logs:"
echo ""
echo ""
echo -e "$log_contents" | tail -n $NUM_LINES