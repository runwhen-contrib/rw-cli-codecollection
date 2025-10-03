#!/bin/bash

# Get or set subscription ID
# Function to extract timestamp from log line, fallback to current time
extract_log_timestamp() {
    local log_line="$1"
    local fallback_timestamp=$(date -u +"%Y-%m-%dT%H:%M:%S.%3NZ")
    
    if [[ -z "$log_line" ]]; then
        echo "$fallback_timestamp"
        return
    fi
    
    # Try to extract common timestamp patterns
    # ISO 8601 format: 2024-01-15T10:30:45.123Z
    if [[ "$log_line" =~ ([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]{3})?Z?) ]]; then
        echo "${BASH_REMATCH[1]}"
        return
    fi
    
    # Standard log format: 2024-01-15 10:30:45
    if [[ "$log_line" =~ ([0-9]{4}-[0-9]{2}-[0-9]{2}[[:space:]]+[0-9]{2}:[0-9]{2}:[0-9]{2}) ]]; then
        # Convert to ISO format
        local extracted_time="${BASH_REMATCH[1]}"
        local iso_time=$(date -d "$extracted_time" -u +"%Y-%m-%dT%H:%M:%S.000Z" 2>/dev/null)
        if [[ $? -eq 0 ]]; then
            echo "$iso_time"
        else
            echo "$fallback_timestamp"
        fi
        return
    fi
    
    # DD-MM-YYYY HH:MM:SS format
    if [[ "$log_line" =~ ([0-9]{2}-[0-9]{2}-[0-9]{4}[[:space:]]+[0-9]{2}:[0-9]{2}:[0-9]{2}) ]]; then
        local extracted_time="${BASH_REMATCH[1]}"
        # Convert DD-MM-YYYY to YYYY-MM-DD for date parsing
        local day=$(echo "$extracted_time" | cut -d' ' -f1 | cut -d'-' -f1)
        local month=$(echo "$extracted_time" | cut -d' ' -f1 | cut -d'-' -f2)
        local year=$(echo "$extracted_time" | cut -d' ' -f1 | cut -d'-' -f3)
        local time_part=$(echo "$extracted_time" | cut -d' ' -f2)
        local iso_time=$(date -d "$year-$month-$day $time_part" -u +"%Y-%m-%dT%H:%M:%S.000Z" 2>/dev/null)
        if [[ $? -eq 0 ]]; then
            echo "$iso_time"
        else
            echo "$fallback_timestamp"
        fi
        return
    fi
    
    # Fallback to current timestamp
    echo "$fallback_timestamp"
}

if [[ -z "${AZURE_RESOURCE_SUBSCRIPTION_ID:-}" ]]; then
    subscription=$(az account show --query "id" -o tsv)
    echo "AZURE_RESOURCE_SUBSCRIPTION_ID is not set. Using current subscription ID: $subscription"
else
    subscription="$AZURE_RESOURCE_SUBSCRIPTION_ID"
    echo "Using specified subscription ID: $subscription"
fi

# Set the subscription to the determined ID
echo "Switching to subscription ID: $subscription"
az account set --subscription "$subscription" || { echo "Failed to set subscription."; exit 1; }

issues_json='{"issues": []}'


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
    # Extract detailed error information from cluster status and agent pools
    CLUSTER_ERROR_JSON=$(echo "$CLUSTER_DETAILS" | jq -c '.status // {}')
    AGENT_POOL_ERRORS_JSON=$(echo "$CLUSTER_DETAILS" | jq -c '[.agentPoolProfiles[] | select(.status != null and .status != {})]')
    
    # Build comprehensive error details with raw JSON
    ERROR_DETAILS="Provisioning state: $PROVISIONING_STATE

Raw Cluster Status:
$CLUSTER_ERROR_JSON

Raw Agent Pool Status Details:
$AGENT_POOL_ERRORS_JSON"
    
    issues_json=$(echo "$issues_json" | jq \
        --arg title "AKS Cluster \`$CLUSTER_NAME\` Provisioning Failure" \
        --arg nextStep "Check the provisioning details and troubleshoot failures in the Azure Portal. Review the detailed error messages to identify specific issues with Pod Disruption Budgets (PDBs), node draining, or other cluster configuration problems." \
        --arg severity "1" \
        --arg details "$ERROR_DETAILS" \
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
        --arg title "AKS Cluster \`$CLUSTER_NAME\` Diagnostics Settings Missing" \
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
        --arg title "AKS Cluster \`$CLUSTER_NAME\` Autoscaling Disabled in Node Pools" \
        --arg nextStep "Enable autoscaling on all node pools for better resource management." \
        --arg severity "4" \
        --arg details "$AUTOSCALING_DISABLED_COUNT node pools have autoscaling disabled." \
        '.issues += [{"title": $title, "next_step": $nextStep, "severity": ($severity | tonumber), "details": $details}]'
    )
else
    echo "All node pools have autoscaling enabled."
fi

# Check for individual agent pool provisioning failures (even if overall cluster state is Succeeded)
FAILED_AGENT_POOLS=$(echo "$CLUSTER_DETAILS" | jq -c '[.agentPoolProfiles[] | select(.provisioningState == "Failed" or .provisioningState == "Canceled")]')

FAILED_POOL_COUNT=$(echo "$FAILED_AGENT_POOLS" | jq 'length')
if [ "$FAILED_POOL_COUNT" -gt 0 ]; then
    FAILED_POOL_DETAILS="Raw Agent Pool Details:
$FAILED_AGENT_POOLS"
    
    echo "$FAILED_POOL_COUNT agent pool(s) have provisioning failures."
    issues_json=$(echo "$issues_json" | jq \
        --arg title "AKS Cluster \`$CLUSTER_NAME\` Agent Pool Provisioning Failures" \
        --arg nextStep "Review the specific agent pool errors and address the underlying issues such as Pod Disruption Budget (PDB) policies, node draining problems, or resource constraints. Check the Azure Portal for detailed troubleshooting guidance." \
        --arg severity "2" \
        --arg details "$FAILED_POOL_DETAILS" \
        '.issues += [{"title": $title, "next_step": $nextStep, "severity": ($severity | tonumber), "details": $details}]'
    )
else
    echo "All agent pools are in non-failure states (no Failed or Canceled pools detected)."
fi

# Dump the issues into a json list for processing
echo "$issues_json" > "az_cluster_health.json"
