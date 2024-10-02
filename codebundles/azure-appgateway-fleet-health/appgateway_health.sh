#!/bin/bash

# ENV:
# AZ_USERNAME
# AZ_SECRET_VALUE
# AZ_TENANT
# AZ_SUBSCRIPTION
# AZ_RESOURCE_GROUP
# APPGATEWAY


# # Log in to Azure CLI
# az login --service-principal --username $AZ_USERNAME --password $AZ_SECRET_VALUE --tenant $AZ_TENANT > /dev/null
# # Set the subscription
# az account set --subscription $AZ_SUBSCRIPTION
echo "Running App Gateway Fleet Health Check"

ok=0

gateway_list=$(az network application-gateway list --resource-group $AZ_RESOURCE_GROUP --query "[].name" --output tsv)
for gateway in $gateway_list; do
    echo "Health Checking Application Gateway $gateway"
    state=$(az network application-gateway show --resource-group $AZ_RESOURCE_GROUP --name $gateway --query "operationalState")
    backend_pools=$(az network application-gateway show-backend-health --resource-group $AZ_RESOURCE_GROUP --name $gateway)
    unhealthy_servers=$(echo $backend_pools | jq -r '.backendAddressPools[].backendHttpSettingsCollection[].servers[] | select(.health != "Healthy")')
    if [ -z "$unhealthy_servers" ]; then
        unhealthy_servers="[]"
    fi
    us_count=$(echo $unhealthy_servers | jq 'length')
    if [ $us_count -gt 0 ]; then
        echo "The Application Gateway $gateway has unhealthy servers in $AZ_RESOURCE_GROUP"
        ok=1
    fi
    if [ "$state" == "\"Running\"" ]; then
        echo "The Application Gateway $gateway is running in $AZ_RESOURCE_GROUP"
    else
        echo "The Application Gateway $gateway is not running in $AZ_RESOURCE_GROUP"
        ok=1
    fi
done

exit $ok