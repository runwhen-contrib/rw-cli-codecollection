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
ok=0
next_steps=()
adf_id=$(az datafactory show --name $ADF --resource-group $AZ_RESOURCE_GROUP --query id --output tsv)
echo "Checking ADF $ADF metrics with ID $adf_id"
most_recent_failed_count=$(az monitor metrics list --resource $adf_id --resource-group $AZ_RESOURCE_GROUP --metric "PipelineFailedRuns" --interval 5m --aggregation maximum --top 1 | jq -r '.value[].timeseries[].data[-1].maximum')
if (( $(echo "$most_recent_failed_count > 0" | bc -l) )); then
    echo "The Azure Data Factory $ADF has failed pipeline runs in $AZ_RESOURCE_GROUP"
    next_steps+=("Check the pipeline runs in the Azure Data Factory $ADF in $AZ_RESOURCE_GROUP\n")
    ok=1
fi
if [ $ok -eq 1 ]; then
    echo "Error: The Azure Data Factory $ADF failed one or more key metric checks"
    echo ""
    echo "Next Steps:"
    echo -e "${next_steps[@]}"
fi