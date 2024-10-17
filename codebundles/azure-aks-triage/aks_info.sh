#!/bin/bash

# ENV:
# AZ_USERNAME
# AZ_SECRET_VALUE
# AZ_SUBSCRIPTION
# AZ_TENANT
# AKS_CLUSTER
# AZ_RESOURCE_GROUP

# # Log in to Azure CLI
# az login --service-principal --username $AZ_USERNAME --password $AZ_SECRET_VALUE --tenant $AZ_TENANT > /dev/null

# # Set the subscription
# az account set --subscription $AZ_SUBSCRIPTION

ok=0
echo "Collecting AKS Cluster Information for cluster $AKS_CLUSTER in resource group $AZ_RESOURCE_GROUP"
echo "..."
AKS_JSON=$(az aks show --resource-group $AZ_RESOURCE_GROUP --name $AKS_CLUSTER)
has_agent_pools=$(echo $AKS_JSON | jq '.agentPoolProfiles' | jq length)
if [ $has_agent_pools -eq 0 ]; then
    ok=1
fi
echo ""
echo ""
echo "AKS Cluster Info:"
echo $AKS_JSON | jq '.'
echo ""
echo "Profiles:"
echo $AKS_JSON | jq '.agentPoolProfiles'
echo ""
if [ $ok -eq 1 ]; then
    echo "Error: No agent pools found. This is likely a misconfiguration."
fi
