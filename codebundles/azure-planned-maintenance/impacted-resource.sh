#!/bin/bash
set -euo pipefail

# -----------------------------------------------------------------------------
# Script: impacted-resource.sh
# Purpose: Fetches impacted resources from Azure Service Health for the specified subscription.
# Inputs (Environment Variables):
#   AZURE_SUBSCRIPTION_ID   (Required): Azure Subscription ID.
# Outputs:
#   File: impacted_resources.json
#         Contains an array of impacted resources.
# -----------------------------------------------------------------------------


# Get or set subscription ID
if [ -z "${AZURE_SUBSCRIPTION_ID:-}" ]; then
    subscription=$(az account show --query "id" -o tsv)
    echo "AZURE_SUBSCRIPTION_ID is not set. Using current subscription ID: $subscription"
else
    subscription="$AZURE_SUBSCRIPTION_ID"
    echo "Using specified subscription ID: $subscription"
fi

# Set the subscription ID
echo "Switching to subscription ID: $subscription"
az account set --subscription "$subscription" || { echo "Failed to set subscription."; exit 1; }

output_file="impacted_resources.json"
temp_file="temp_impacted_resources.json"

# Check for required Azure CLI extensions
check_extension() {
    local extension=$1
    echo "Checking for '$extension' Azure CLI extension..."
    if ! az extension show --name "$extension" &>/dev/null; then
        echo "Installing '$extension' extension..."
        az extension add --name "$extension" --yes || {
            echo "ERROR: Failed to install '$extension' Azure CLI extension." >&2
            exit 1
        }
        echo "'$extension' extension installed successfully."
    else
        echo "'$extension' extension is already installed."
    fi
}

# Install required extensions
check_extension "resource-graph"
check_extension "account"

# KQL Query for impacted resources
query="
ServiceHealthResources
| where type == 'microsoft.resourcehealth/events/impactedresources'
| extend TrackingId = split(split(id, '/events/', 1)[0], '/impactedResources', 0)[0]
| extend p = parse_json(properties)
| project subscriptionId, TrackingId, resourceName=p.resourceName, resourceGroup=p.resourceGroup, resourceType=p.targetResourceType, details = p, id
"

echo "Fetching impacted resources from Azure..."
if ! resources_result=$(az graph query -q "$query" --subscriptions "$subscription" -o json 2>/dev/null); then
    echo "ERROR: Failed to retrieve impacted resources from Azure." >&2
    echo "[]" > "$output_file"
    exit 1
fi

echo "Processing results..."
count=$(echo "$resources_result" | jq -r '.data | length' 2>/dev/null || echo "0")
echo "Found $count impacted resources."

processed_resources=()
for ((i=0; i<count; i++)); do
    resource=$(echo "$resources_result" | jq -c ".data[$i]" 2>/dev/null)
    processed_resources+=("$resource")
done

# Combine all resources into a JSON array
result_json=$(printf '%s\n' "${processed_resources[@]}" | jq -s '.')

# Save to output file
echo "$result_json" > "$output_file"

# Clean up
rm -f "$temp_file" 2>/dev/null || true

echo "Results saved to $output_file"
echo "--- Azure Impacted Resource Retrieval Finished ---"

exit 0
