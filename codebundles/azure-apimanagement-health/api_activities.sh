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

echo "Azure API Management $API activity logs (recent):"
# Get the activity logs of the vm scaled set
resource_id=$(az apim show --name $API --resource-group $AZ_RESOURCE_GROUP --subscription $AZ_SUBSCRIPTION --query "id")
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