#!/bin/bash

# Input variables for subscription ID, cluster name, and resource group
subscription=$(az account show --query "id" -o tsv)
issues_json='{"issues": []}'

# Set the subscription to the specified ID
echo "Switching to subscription ID: $AZURE_RESOURCE_SUBSCRIPTION_ID"
az account set --subscription "$AZURE_RESOURCE_SUBSCRIPTION_ID" || { echo "Failed to set subscription."; exit 1; }


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

# Share raw output
echo "-------Raw Cluster Details--------"
echo "$CLUSTER_DETAILS" | jq .

# Checks and outputs
echo "-------Configuration Summary--------"
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

# Add an issue if provisioning failed
if [ "$PROVISIONING_STATE" != "Succeeded" ]; then
    issues_json=$(echo "$issues_json" | jq \
        --arg title "Provisioning Failure" \
        --arg nextStep "Check the provisioning details and troubleshoot failures in the Azure Portal." \
        --arg severity "1" \
        --arg details "Provisioning state: $PROVISIONING_STATE" \
        '.issues += [{"title": $title, "next_step": $nextStep, "severity": ($severity | tonumber), "details": $details}]'
    )
    echo "Issue Detected: Provisioning has failed."
fi

# Check for diagnostics settings
DIAGNOSTIC_SETTINGS=$(az monitor diagnostic-settings list --resource "$ID" -o json | jq 'length')
if [ "$DIAGNOSTIC_SETTINGS" -gt 0 ]; then
    echo "Diagnostics settings are enabled."
else
    echo "Diagnostics settings are not enabled."
    issues_json=$(echo "$issues_json" | jq \
        --arg title "Diagnostics Settings Missing" \
        --arg nextStep "Enable diagnostics settings in the Azure Portal to capture logs and metrics." \
        --arg severity "4" \
        --arg details "Diagnostics settings are not configured for this resource." \
        '.issues += [{"title": $title, "next_step": $nextStep, "severity": ($severity | tonumber), "details": $details}]'
    )
fi

# Check if any node pools have autoscaling disabled
AUTOSCALING_DISABLED_COUNT=$(echo "$CLUSTER_DETAILS" | jq '[.agentPoolProfiles[] | select(.enableAutoScaling == null)] | length')
if [ "$AUTOSCALING_DISABLED_COUNT" -gt 0 ]; then
    echo "$AUTOSCALING_DISABLED_COUNT node pools do not have autoscaling enabled."
    issues_json=$(echo "$issues_json" | jq \
        --arg title "Autoscaling Disabled in Node Pools" \
        --arg nextStep "Enable autoscaling on all node pools for better resource management." \
        --arg severity "3" \
        --arg details "$AUTOSCALING_DISABLED_COUNT node pools have autoscaling disabled." \
        '.issues += [{"title": $title, "next_step": $nextStep, "severity": ($severity | tonumber), "details": $details}]'
    )
else
    echo "All node pools have autoscaling enabled."
fi

# Dump the issues into a json list for processing
echo "$issues_json" > "$OUTPUT_DIR/az_cluster_health.json"
