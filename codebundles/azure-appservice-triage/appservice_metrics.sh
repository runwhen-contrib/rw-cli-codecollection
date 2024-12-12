#!/bin/bash

# ENV:
# AZ_USERNAME
# AZ_SECRET_VALUE
# AZ_TENANT
# AZ_SUBSCRIPTION
# AZ_RESOURCE_GROUP
# APP_SERVICE_NAME

CPU_METRIC="CpuPercentage"
MEM_METRIC="MemoryPercentage"
BYTES_IN_METRIC="BytesReceived"
BYTES_OUT_METRIC="BytesSent"
ERROR_METRIC="Http5xx"

ALLOWED_ERRORS=0
ALLOWED_CPU=80
ALLOWED_MEM=80
BYTE_THRESHOLD=1
METRIC_TOP=100

subscription_id=$(az account show --query "id" -o tsv)

# # Set the subscription
az account set --subscription $subscription_id

# get service plan in order to fetch other metrics
service_plan=$(az webapp show --name $APP_SERVICE_NAME --resource-group $AZ_RESOURCE_GROUP --query appServicePlanId)


ok=0
next_steps=()
cpu_data=$(az monitor metrics list --resource $service_plan --metric "$CPU_METRIC" --interval 5m --aggregation maximum --top $METRIC_TOP)
mem_data=$(az monitor metrics list --resource $service_plan --metric "$MEM_METRIC" --interval 5m --aggregation maximum --top $METRIC_TOP)
bytes_in_data=$(az monitor metrics list --resource $APP_SERVICE_NAME --resource-group $AZ_RESOURCE_GROUP --resource-type Microsoft.Web/sites --metric "$BYTES_IN_METRIC" --interval 5m --aggregation average --top $METRIC_TOP)
bytes_out_data=$(az monitor metrics list --resource $APP_SERVICE_NAME --resource-group $AZ_RESOURCE_GROUP --resource-type Microsoft.Web/sites --metric "$BYTES_OUT_METRIC" --interval 5m --aggregation average --top $METRIC_TOP)
error_data=$(az monitor metrics list --resource $APP_SERVICE_NAME --resource-group $AZ_RESOURCE_GROUP --resource-type Microsoft.Web/sites --metric "$ERROR_METRIC" --interval 5m --aggregation maximum --top $METRIC_TOP)

for metric in $(echo "$cpu_data" | jq -r '.value[].timeseries[].data[].maximum | numbers'); do
    if (( $(echo "$metric > $ALLOWED_CPU" | bc -l) )); then
        echo "Found CPU usage above the allowed threshold: $ALLOWED_CPU for Azure App Service $APP_SERVICE_NAME in $AZ_RESOURCE_GROUP"
        next_steps+=("Increase Azure App Service $APP_SERVICE_NAME CPU\n")
        ok=1
        break
    fi
done
for metric in $(echo "$mem_data" | jq -r '.value[].timeseries[].data[].maximum'); do
    if [[ $metric -gt $ALLOWED_MEM ]]; then
        echo "Found Memory usage above the allowed threshold: $ALLOWED_MEM for Azure App Service $APP_SERVICE_NAME in $AZ_RESOURCE_GROUP"
        next_steps+=("Increase Azure App Service $APP_SERVICE_NAME memory\n")
        ok=1
        break
    fi
done
for metric in $(echo "$bytes_in_data" | jq -r '.value[].timeseries[].data[].average'); do
    if [[ $metric -lt $BYTE_THRESHOLD ]]; then
        echo "App service $APP_SERVICE_NAME has low or no bytes received, where threshold is set as: $BYTE_THRESHOLD"
        next_steps+=("Verify that Azure App Service $APP_SERVICE_NAME in $AZ_RESOURCE_GROUP healthy and that the network is configured correctly\n")
        ok=1
        break
    fi
done
# for metric in $(echo "$bytes_out_data" | jq -r '.value[].timeseries[].data[].average'); do
#     if [[ $metric -lt $BYTE_THRESHOLD ]]; then
#         echo "App service $APP_SERVICE_NAME has low or no bytes sent, where threshold is set as: $BYTE_THRESHOLD"
#         next_steps+=("Verify that Azure App Service $APP_SERVICE_NAME in $AZ_RESOURCE_GROUP healthy and that the network is configured correctly\n")
#         ok=1
#         break
#     fi
# done
for metric in $(echo "$error_data" | jq -r '.value[].timeseries[].data[].maximum'); do
    if [[ $metric -gt $ALLOWED_ERRORS ]]; then
        echo "Found HTTP 5xx errors above the allowed threshold: $ALLOWED_ERRORS for $APP_SERVICE_NAME"
        next_steps+=("Investigate the HTTP 5xx errors for Azure App Service $APP_SERVICE_NAME in $AZ_RESOURCE_GROUP\n")
        ok=1
        break
    fi
done

if [ $ok -eq 1 ]; then
    echo "Error: The Azure App Service $APP_SERVICE_NAME failed one or more key metric checks"
    echo ""
    echo "Next Steps:"
    echo -e "${next_steps[@]}"
    exit 1
else
    echo "Azure App Service $APP_SERVICE_NAME in $AZ_RESOURCE_GROUP passed all key metric checks"
    exit 0
fi