#!/bin/bash

# Input variables for subscription ID, cluster name, and resource group
subscription=$(az account show --query "id" -o tsv)

# Get cluster details
CLUSTER_DETAILS=$(az aks show --name "$AKS_CLUSTER" --resource-group "$AZ_RESOURCE_GROUP" -o json)

# Extract relevant information from JSON response
CLUSTER_NAME=$AKS_CLUSTER
ID=$(echo "$CLUSTER_DETAILS" | jq -r '.id')
CLUSTER_LOCATION=$(echo "$CLUSTER_DETAILS" | jq -r '.location')
CLUSTER_RG=$(echo "$CLUSTER_DETAILS" | jq -r '.resourceGroup')
NODE_RG=$(echo "$CLUSTER_DETAILS" | jq -r '.nodeResourceGroup')
TOTAL_NODE_COUNT=$(echo "$CLUSTER_DETAILS" | jq -r '[.agentPoolProfiles[].count] | add')
PROVISIONING_STATE=$(echo "$CLUSTER_DETAILS" | jq -r '.provisioningState')
NETWORK_POLICY=$(echo "$CLUSTER_DETAILS" | jq -r '.networkProfile.networkPolicy')
PRIVATE_CLUSTER=$(echo "$CLUSTER_DETAILS" | jq -r '.apiServerAccessProfile.enablePrivateCluster')
RBAC_ENABLED=$(echo "$CLUSTER_DETAILS" | jq -r '.enableRbac')
LOAD_BALANCER_SKU=$(echo "$CLUSTER_DETAILS" | jq -r '.networkProfile.loadBalancerSku')

# Checks and outputs
echo "Cluster Name: $CLUSTER_NAME"
echo "Location: $CLUSTER_LOCATION"
echo "Resource Group: $CLUSTER_RG"
echo "Node Resource Group: $NODE_RG"
echo "Total Node Count: $TOTAL_NODE_COUNT"
echo "Provisioning State: $PROVISIONING_STATE"
echo "Network Policy: $NETWORK_POLICY"
echo "Private Cluster: $PRIVATE_CLUSTER"
echo "RBAC Enabled: $RBAC_ENABLED"
echo "Load Balancer SKU: $LOAD_BALANCER_SKU"

# Check for diagnostics settings
DIAGNOSTIC_SETTINGS=$(az monitor diagnostic-settings list --resource "$ID" -o json | jq 'length')
if [ "$DIAGNOSTIC_SETTINGS" -gt 0 ]; then
    echo "Diagnostics settings are enabled."
else
    echo "Diagnostics settings are not enabled."
fi

# Additional checks (example): Check if any node pools have autoscaling disabled
AUTOSCALING_DISABLED_COUNT=$(echo "$CLUSTER_DETAILS" | jq '[.agentPoolProfiles[] | select(.enableAutoScaling == null)] | length')
if [ "$AUTOSCALING_DISABLED_COUNT" -gt 0 ]; then
    echo "$AUTOSCALING_DISABLED_COUNT node pools do not have autoscaling enabled."
else
    echo "All node pools have autoscaling enabled."
fi
