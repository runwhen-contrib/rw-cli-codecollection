#!/bin/bash
set -euo pipefail

# -----------------------------------------------------------------------------
# REQUIRED ENV VARS:
#   AZURE_SUBSCRIPTION_ID
#   AZURE_RESOURCE_GROUP
# -----------------------------------------------------------------------------

: "${AZURE_SUBSCRIPTION_ID:?Must set AZURE_SUBSCRIPTION_ID}"
: "${AZURE_RESOURCE_GROUP:?Must set AZURE_RESOURCE_GROUP}"

subscription_id="$AZURE_SUBSCRIPTION_ID"
resource_group="$AZURE_RESOURCE_GROUP"

echo "Testing connection for all linked services in resource group $resource_group:"
echo "--------------------------------------------------------"

# Function to test connection for a linked service
test_linked_service_connection() {
    local data_factory=$1
    local service_name=$2
    echo "Testing connection for: $service_name in Data Factory $data_factory"
    
    # Check if the linked service exists
    linked_service_exists=$(az datafactory linked-service show \
        --resource-group $resource_group \
        --factory-name $data_factory \
        --name $service_name \
        --query "name" -o tsv 2>/dev/null || true)
    
    if [[ -z "$linked_service_exists" ]]; then
        echo "❌ Linked service $service_name not found in Data Factory $data_factory"
        echo "--------------------------------------------------------"
        return
    fi
    echo "https://management.azure.com/subscriptions/$subscription_id/resourceGroups/$resource_group/providers/Microsoft.DataFactory/factories/$data_factory/linkedservices/$service_name/testconnection?api-version=2018-06-01"
    # Test the connection
    response=$(az rest --method get \
        --uri "https://management.azure.com/subscriptions/$subscription_id/resourceGroups/$resource_group/providers/Microsoft.DataFactory/factories/$data_factory/linkedservices/$service_name/testconnection?api-version=2018-06-01")
    echo $response
    if [[ $response == *"ConnectionTest successfully completed."* ]]; then
        echo "✅ Connection successful for $service_name in Data Factory $data_factory"
    else
        echo "❌ Connection failed for $service_name in Data Factory $data_factory"
        echo "Error: $response"
    fi
    echo "--------------------------------------------------------"
}

# Get all data factories in the resource group
data_factories=$(az datafactory list \
    --resource-group $resource_group \
    --subscription $subscription_id \
    --query "[].name" -o tsv)

if [[ -z "$data_factories" ]]; then
    echo "No Data Factories found in resource group $resource_group"
    exit 0
fi

# Loop over each data factory
for data_factory in $data_factories; do
    echo "Processing Data Factory: $data_factory"
    
    # Get all linked services in the data factory
    linked_services=$(az datafactory linked-service list \
        --resource-group $resource_group \
        --factory-name $data_factory \
        --query "[].name" -o tsv)

    # Test each linked service
    for service in $linked_services; do
        test_linked_service_connection "$data_factory" "$service"
    done
done