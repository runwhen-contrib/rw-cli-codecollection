#!/bin/bash

# ENV:
# AZ_USERNAME
# AZ_SECRET_VALUE
# AZ_SUBSCRIPTION
# AZ_TENANT
# APPSERVICE
# AZ_RESOURCE_GROUP

WEBAPP_TYPE="Microsoft.Web/sites"

subscription_id=$(az account show --query "id" -o tsv)

# # Set the subscription
az account set --subscription $subscription_id

echo "Azure App Service $APPSERVICE activity logs (recent):"
# Get the activity logs of the web app
resource_id=$(az webapp show --name $APPSERVICE --resource-group $AZ_RESOURCE_GROUP --subscription $subscription_id --query "id")
az monitor activity-log list --resource-id $resource_id --resource-group $AZ_RESOURCE_GROUP --output table

# TODO: hook into various activities to create suggestions

ok=0
next_steps=()
activities=$(az monitor activity-log list --resource-id $resource_id --resource-group $AZ_RESOURCE_GROUP --output table)
if [[ $activities == *"Critical"* ]]; then
    echo "There are critical activities logs of the Azure resource: $resource_id in $AZ_RESOURCE_GROUP"
    next_steps+=("Check the critical-level activity logs of the azure resource $resource_id in $AZ_RESOURCE_GROUP\n")
    ok=1
fi
if [[ $activities == *"Error"* ]]; then
    echo "There are error activities logs of the Azure resource: $resource_id in $AZ_RESOURCE_GROUP"
    next_steps+=("Check the error-level activity logs of the azure resource $resource_id in $AZ_RESOURCE_GROUP\n")
    ok=1
fi
if [[ $activities == *"Warning"* ]]; then
    echo "There are warning activities logs of the Azure resource: $resource_id in $AZ_RESOURCE_GROUP"
    next_steps+=("Check the warning-level activity logs of the azure resource $resource_id in $AZ_RESOURCE_GROUP\n")
    ok=1
fi
if [ $ok -eq 1 ]; then
    echo "Issue: Azure resource has non-informational activity logs"
    echo ""
    echo "Next Steps:"
    echo -e "${next_steps[@]}"
fi