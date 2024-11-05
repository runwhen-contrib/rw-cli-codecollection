#!/bin/bash

# Set subscription ID and resource details
subscription=$(az account show --query "id" -o tsv)

# Check if Microsoft.ResourceHealth provider is already registered
echo "Checking registration status of Microsoft.ResourceHealth provider..."
registrationState=$(az provider show --namespace Microsoft.ResourceHealth --query "registrationState" -o tsv)

if [[ "$registrationState" != "Registered" ]]; then
    echo "Registering Microsoft.ResourceHealth provider..."
    az provider register --namespace Microsoft.ResourceHealth

    # Wait for the provider to be registered
    echo "Waiting for Microsoft.ResourceHealth provider to register..."
    for i in {1..10}; do
        registrationState=$(az provider show --namespace Microsoft.ResourceHealth --query "registrationState" -o tsv)
        if [[ "$registrationState" == "Registered" ]]; then
            echo "Microsoft.ResourceHealth provider registered successfully."
            break
        else
            echo "Current registration state: $registrationState. Retrying in 10 seconds..."
            sleep 10
        fi
    done

    # Check if the provider is not registered after waiting
    if [[ "$registrationState" != "Registered" ]]; then
        echo "Error: Microsoft.ResourceHealth provider could not be registered."
        exit 1
    fi
else
    echo "Microsoft.ResourceHealth provider is already registered."
fi

# Perform the REST API call to get the resource health status
echo "Retrieving health status for AKS cluster..."
az rest --method get --url "https://management.azure.com/subscriptions/$subscription/resourceGroups/$AZ_RESOURCE_GROUP/providers/Microsoft.ContainerService/managedClusters/$AKS_CLUSTER/providers/Microsoft.ResourceHealth/availabilityStatuses/current?api-version=2023-07-01-preview" > ${OUTPUT_DIR}/az_resource_health.json

cat ${OUTPUT_DIR}/az_resource_health.json
