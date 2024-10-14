#!/bin/bash

# ENV:
# AZ_USERNAME
# AZ_SECRET_VALUE
# AZ_SUBSCRIPTION
# AZ_TENANT
# ADF
# AZ_RESOURCE_GROUP

# # Log in to Azure CLI
# az login --service-principal --username $AZ_USERNAME --password $AZ_SECRET_VALUE --tenant $AZ_TENANT > /dev/null

# # Set the subscription
# az account set --subscription $AZ_SUBSCRIPTION

# az extension add --name datafactory

P_FAILED_METRIC="PipelineFailedRuns"
P_SUCCEDED_METRIC="PipelineSucceededRuns"
A_Failed_METRIC="ActivityFailedRuns"
A_SUCCEEDED_METRIC="ActivitySucceededRuns"
CPU_METRIC="IntegrationRuntimeCpuPercentage"
QUEUE_METRIC="IntegrationRuntimeQueueLength"
MAX_CPU_ALLOWED=80


next_steps=()

ok=0
adf_id=$(az datafactory show --name $ADF --resource-group $AZ_RESOURCE_GROUP --query id --output tsv)
echo "Checking ADF $ADF metrics with ID $adf_id"
echo "Checking Pipeline Failed Runs"
most_recent_failed_count=$(az monitor metrics list --resource $adf_id --resource-group $AZ_RESOURCE_GROUP --metric $P_FAILED_METRIC --interval 5m --aggregation maximum --top 1 | jq -r '.value[].timeseries[].data[-1].maximum')
if (( $(echo "$most_recent_failed_count > 0" | bc -l) )); then
    echo "The Azure Data Factory $ADF has failed pipeline runs in $AZ_RESOURCE_GROUP"
    next_steps+=("Check the pipeline runs in the Azure Data Factory $ADF in $AZ_RESOURCE_GROUP\n")
    ok=1
fi
echo "Checking Pipeline Succeeded Runs"
most_recent_succeeded_count=$(az monitor metrics list --resource $adf_id --resource-group $AZ_RESOURCE_GROUP --metric $P_SUCCEDED_METRIC --interval 30m --aggregation average --top 200 | jq -r '[.value[].timeseries[].data[].average] | max')
if (( $(echo "$most_recent_succeeded_count == 0" | bc -l) )); then
    echo "The Azure Data Factory $ADF has no succeeded pipeline runs in $AZ_RESOURCE_GROUP"
    next_steps+=("Investigate why there are no succeeded pipeline runs in the Azure Data Factory $ADF in $AZ_RESOURCE_GROUP\n")
    ok=1
fi
echo "Checking Activity Failed Runs"
most_recent_failed_count=$(az monitor metrics list --resource $adf_id --resource-group $AZ_RESOURCE_GROUP --metric $A_Failed_METRIC --interval 5m --aggregation maximum --top 1 | jq -r '.value[].timeseries[].data[-1].maximum')
if (( $(echo "$most_recent_failed_count > 0" | bc -l) )); then
    echo "The Azure Data Factory $ADF has failed activity runs in $AZ_RESOURCE_GROUP"
    next_steps+=("Check the activity runs in the Azure Data Factory $ADF in $AZ_RESOURCE_GROUP\n")
    ok=1
fi
echo "Checking Activity Succeeded Runs"
most_recent_succeeded_count=$(az monitor metrics list --resource $adf_id --resource-group $AZ_RESOURCE_GROUP --metric $A_SUCCEEDED_METRIC --interval 30m --aggregation average --top 200 | jq -r '[.value[].timeseries[].data[].average] | max')
if (( $(echo "$most_recent_succeeded_count == 0" | bc -l) )); then
    echo "The Azure Data Factory $ADF has no succeeded activity runs in $AZ_RESOURCE_GROUP"
    next_steps+=("Investigate why there are no succeeded activity runs in the Azure Data Factory $ADF in $AZ_RESOURCE_GROUP\n")
    ok=1
fi
echo "Checking Integration Runtime CPU Percentage"
most_recent_cpu_percentage=$(az monitor metrics list --resource $adf_id --resource-group $AZ_RESOURCE_GROUP --metric $CPU_METRIC --interval 5m --aggregation maximum --top 1 | jq -r '.value[].timeseries[].data[-1].maximum')
if (( $(echo "$most_recent_cpu_percentage > $MAX_CPU_ALLOWED" | bc -l) )); then
    echo "The Azure Data Factory $ADF has high CPU usage in $AZ_RESOURCE_GROUP"
    next_steps+=("Check the CPU usage in the Azure Data Factory $ADF in $AZ_RESOURCE_GROUP\n")
    ok=1
fi
# echo "Checking Integration Runtime Queue Length"
# most_recent_queue_length=$(az monitor metrics list --resource $adf_id --resource-group $AZ_RESOURCE_GROUP --metric $QUEUE_METRIC --interval 5m --aggregation maximum --top 1 | jq -r '.value[].timeseries[].data[-1].maximum')
# if (( $(echo "$most_recent_queue_length > 0" | bc -l) )); then
#     echo "The Azure Data Factory $ADF has a high queue length in $AZ_RESOURCE_GROUP"
#     next_steps+=("Check the queue length in the Azure Data Factory $ADF in $AZ_RESOURCE_GROUP\n")
#     ok=1
# fi
if [ $ok -eq 1 ]; then
    echo "Error: The Azure Data Factory $ADF failed one or more key metric checks"
    echo ""
    echo "Next Steps:"
    echo -e "${next_steps[@]}"
elif [ $ok -eq 0 ]; then
    echo "Success: The Azure Data Factory $ADF passed all key metric checks"
fi