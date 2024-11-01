#!/bin/bash

# Set variables
AZ_RESOURCE_GROUP="<YourResourceGroup>"
AKS_CLUSTER="<YourAKSClusterName>"
LOG_ANALYTICS_WORKSPACE_ID="<YourLogAnalyticsWorkspaceResourceID>"
LOG_SETTING_NAME="AKS-Temporary-Diagnostics"
TIMESTAMP_TAG="DiagnosticStartTime"

# Enable diagnostic logging
echo "Enabling diagnostic logging for AKS cluster $AKS_CLUSTER in resource group $AZ_RESOURCE_GROUP..."
az monitor diagnostic-settings create \
  --name "$LOG_SETTING_NAME" \
  --resource "/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$AZ_RESOURCE_GROUP/providers/Microsoft.ContainerService/managedClusters/$AKS_CLUSTER" \
  --workspace "$LOG_ANALYTICS_WORKSPACE_ID" \
  --logs '[{"category": "kube-apiserver", "enabled": true}, {"category": "kube-controller-manager", "enabled": true}, {"category": "kube-scheduler", "enabled": true}, {"category": "kube-audit", "enabled": true}, {"category": "kube-audit-admin", "enabled": true}]' \
  --metrics '[{"category": "AllMetrics", "enabled": true}]'

# Record the current timestamp in a tag
current_time=$(date +%s)
az resource tag --tags "$TIMESTAMP_TAG=$current_time" \
  --resource-type "Microsoft.ContainerService/managedClusters" \
  --name "$AKS_CLUSTER" \
  --resource-group "$AZ_RESOURCE_GROUP"

echo "Diagnostic logging enabled. Timestamp tag set on AKS cluster."
