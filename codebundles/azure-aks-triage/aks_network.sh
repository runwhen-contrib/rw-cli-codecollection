#!/bin/bash

# Check if AZURE_RESOURCE_SUBSCRIPTION_ID is set, otherwise get the current subscription ID
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

if [ -z "$AZURE_RESOURCE_SUBSCRIPTION_ID" ]; then
    subscription=$(az account show --query "id" -o tsv)
    echo "AZURE_RESOURCE_SUBSCRIPTION_ID is not set. Using current subscription ID: $subscription"
else
    subscription="$AZURE_RESOURCE_SUBSCRIPTION_ID"
    echo "Using specified subscription ID: $subscription"
fi

# Set the subscription to the determined ID
echo "Switching to subscription ID: $subscription"
az account set --subscription "$subscription" || { echo "Failed to set subscription."; exit 1; }


# Ensure required environment variables are set
if [ -z "$AZ_RESOURCE_GROUP" ] || [ -z "$AKS_CLUSTER" ]; then
  echo "Please set AZ_RESOURCE_GROUP and AKS_CLUSTER environment variables."
  exit 1
fi

# Base Azure Portal URL for generating links
BASE_PORTAL_URL="https://portal.azure.com/#resource"

# Get AKS Network Profile
echo "Fetching AKS network profile..."
NETWORK_PROFILE=$(az aks show --resource-group "$AZ_RESOURCE_GROUP" --name "$AKS_CLUSTER" --query "networkProfile" -o json)

# Extract VNET and Subnet IDs from Agent Pool Profile instead of Network Profile
VNET_ID=$(az aks show --resource-group "$AZ_RESOURCE_GROUP" --name "$AKS_CLUSTER" --query "agentPoolProfiles[0].vnetSubnetId" -o tsv | awk -F'/subnets' '{print $1}')
SUBNET_ID=$(az aks show --resource-group "$AZ_RESOURCE_GROUP" --name "$AKS_CLUSTER" --query "agentPoolProfiles[0].vnetSubnetId" -o tsv)
echo ""
echo "------VNET------"
if [ -n "$VNET_ID" ] && [ -n "$SUBNET_ID" ]; then
  echo "Virtual Network ID: $VNET_ID"
  echo "Subnet ID: $SUBNET_ID"
else
  echo "Warning: No custom VNET or subnet found in the agent pool profile."
  echo "The cluster is using Azure CNI without a user-managed VNET."
  echo "Recommendation: For more control over networking, create the AKS cluster with a user-managed VNET."
fi

# Proceed with NSG and Route Table checks only if VNET and Subnet are available
# Check Network Security Groups (NSGs) associated with the subnet
echo ""
echo "------NSG------"
echo "Checking NSGs for the subnet..."
NSG_ID=$(az network vnet subnet show --ids "$SUBNET_ID" --query "networkSecurityGroup.id" -o tsv)

if [ -n "$NSG_ID" ]; then
  echo "NSG ID: $NSG_ID"
  echo "NSG Rules:"
  az network nsg rule list --nsg-name "$(basename "$NSG_ID")" --resource-group "$AZ_RESOURCE_GROUP" -o table

  # Additional NSG rule checks
  RULES=$(az network nsg rule list --nsg-name "$(basename "$NSG_ID")" --resource-group "$AZ_RESOURCE_GROUP" -o json)
  INBOUND_HTTP=$(echo "$RULES" | jq '.[] | select(.access=="Allow" and .direction=="Inbound" and .destinationPortRange=="80")')
  if [ -z "$INBOUND_HTTP" ]; then
    echo "Recommendation: Add a rule to allow inbound HTTP (port 80) if your application requires public access."
  fi

  OUTBOUND_INTERNET=$(echo "$RULES" | jq '.[] | select(.access=="Allow" and .direction=="Outbound" and .destinationAddressPrefix=="Internet")')
  if [ -z "$OUTBOUND_INTERNET" ]; then
    echo "Recommendation: Add a rule to allow outbound internet access if your cluster requires access to public resources."
  fi
else
  echo "No NSG associated with the subnet."
  echo "Recommendation: Associate an NSG with the subnet to control inbound and outbound traffic."
fi

# Get Route Table details for the subnet
echo ""
echo "------Routing------"
echo "Checking route table for the subnet..."
ROUTE_TABLE_ID=$(az network vnet subnet show --ids "$SUBNET_ID" --query "routeTable.id" -o tsv)

if [ -n "$ROUTE_TABLE_ID" ]; then
  echo "Route Table ID: $ROUTE_TABLE_ID"
  az network route-table route list --route-table-name "$(basename "$ROUTE_TABLE_ID")" --resource-group "$AZ_RESOURCE_GROUP" -o table

  ROUTES=$(az network route-table route list --route-table-name "$(basename "$ROUTE_TABLE_ID")" --resource-group "$AZ_RESOURCE_GROUP" -o json)
  INTERNET_ROUTE=$(echo "$ROUTES" | jq '.[] | select(.addressPrefix=="0.0.0.0/0")')
  if [ -z "$INTERNET_ROUTE" ]; then
    echo "Recommendation: Add a default route (0.0.0.0/0) if the cluster requires internet access."
  fi
else
  echo "No Route Table associated with the subnet."
  echo "Recommendation: Consider adding a Route Table to the subnet to manage egress traffic."
fi

# Check if Firewall is present in the resource group
echo ""
echo "------Firewall------"
echo "Checking if Azure Firewall exists in the resource group..."
az config set extension.use_dynamic_install=yes_without_prompt
FIREWALL_PRESENT=$(az network firewall list --resource-group "$AZ_RESOURCE_GROUP" --query "[?provisioningState=='Succeeded'].id" -o tsv)

if [ -z "$FIREWALL_PRESENT" ]; then
  echo "No Azure Firewall detected in the resource group."
  echo "Recommendation: For secure outbound access, consider adding an Azure Firewall or an NVA in the VNET."
else
  echo "Azure Firewall found: $FIREWALL_PRESENT"
fi

echo ""
echo "------Helpful URLS------"
echo "URL to AKS Cluster: ${BASE_PORTAL_URL}/subscriptions/$(az account show --query id -o tsv)/resourceGroups/$AZ_RESOURCE_GROUP/providers/Microsoft.ContainerService/managedClusters/$AKS_CLUSTER"
echo "URL to Resource Group: ${BASE_PORTAL_URL}/subscriptions/$(az account show --query id -o tsv)/resourceGroups/$AZ_RESOURCE_GROUP"
echo "URL to Virtual Network: ${BASE_PORTAL_URL}${VNET_ID}"
echo "URL to NSG: ${BASE_PORTAL_URL}${NSG_ID}"
echo "URL to NSG Rules: ${BASE_PORTAL_URL}${NSG_ID}/securityRules"
echo "URL to Route Table: ${BASE_PORTAL_URL}${ROUTE_TABLE_ID}"
echo "URL to Subnet: ${BASE_PORTAL_URL}${SUBNET_ID}"
if [ "$FIREWALL_PRESENT" ]; then
    echo "URL to Azure Firewall: ${BASE_PORTAL_URL}${FIREWALL_PRESENT}"
fi
