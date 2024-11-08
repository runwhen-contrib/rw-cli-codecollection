#!/bin/bash

# ENV:
# AZ_USERNAME
# AZ_SECRET_VALUE
# AZ_TENANT
# AZ_SUBSCRIPTION
# AZ_RESOURCE_GROUP
# APPGATEWAY

#Microsoft.Network/applicationGateways

METRIC_TOP=100

# # Log in to Azure CLI
# az login --service-principal --username $AZ_USERNAME --password $AZ_SECRET_VALUE --tenant $AZ_TENANT > /dev/null
# # Set the subscription
# az account set --subscription $AZ_SUBSCRIPTION

ok=0
next_steps=()
fq_data=$(az monitor metrics list --resource $APPGATEWAY --resource-group $AZ_RESOURCE_GROUP --resource-type Microsoft.Network/applicationGateways --metric "FailedRequests" --interval 5m --aggregation maximum --top $METRIC_TOP)
uh_data=$(az monitor metrics list --resource $APPGATEWAY --resource-group $AZ_RESOURCE_GROUP --resource-type Microsoft.Network/applicationGateways --metric "UnhealthyHostCount" --interval 5m --aggregation maximum --top $METRIC_TOP)


# Check if "maximum" is available in the JSON
if echo "$fq_data" | jq -e '.value[].timeseries[].data[].maximum' >/dev/null; then
    # Loop through the "minimum" values
    for metric in $(echo "$fq_data" | jq -r '.value[].timeseries[].data[].maximum'); do
        if (( $(echo "$metric > 0" | bc -l) )); then
            echo "The Application Gateway $APPGATEWAY has failed requests in $AZ_RESOURCE_GROUP"
            next_steps+=("Tail the logs of the workloads in the backend pool of the Application Gateway $APPGATEWAY in $AZ_RESOURCE_GROUP\n")
            ok=1
            break
        fi
    done
else
    echo "No 'maximum' field available in the JSON data."
fi

# Check if "maximum" is available in the JSON
if echo "$uh_data" | jq -e '.value[].timeseries[].data[].maximum' >/dev/null; then
    # Loop through the "minimum" values
    for metric in $(echo "$uh_data" | jq -r '.value[].timeseries[].data[].maximum'); do
        if (( $(echo "$metric > 0" | bc -l) )); then
            echo "The Application Gateway $APPGATEWAY has unhealthy in $AZ_RESOURCE_GROUP"
            next_steps+=("Tail the logs of the workloads in the backend pool of the Application Gateway $APPGATEWAY in $AZ_RESOURCE_GROUP\n")
            ok=1
            break
        fi
    done
else
    echo "No 'maximum' field available in the JSON data."
fi

if [ $ok -eq 1 ]; then
    echo "Error: The Azure Application Gateway $APPGATEWAY failed one or more key metric checks"
    echo ""
    echo "Next Steps:"
    echo -e "${next_steps[@]}"
    exit 1
else
    echo "Azure Application Gateway $APPGATEWAY in $AZ_RESOURCE_GROUP passed all key metric checks"
    exit 0
fi