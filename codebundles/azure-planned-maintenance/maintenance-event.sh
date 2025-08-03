#!/bin/bash
set -euo pipefail

# -----------------------------------------------------------------------------
# Script: maintenance-event.sh
# Purpose: Fetches planned maintenance events from Azure Service Health and 
#          their impacted resources for the specified subscription.
#
# Inputs (Environment Variables):
#   AZURE_SUBSCRIPTION_ID   (Required): Azure Subscription ID.
#
# Outputs:
#   File: maintenance_events.json
#         Contains an array of Azure Planned Maintenance events with parsed impact data.
# -----------------------------------------------------------------------------

# Get or set subscription ID
if [ -z "$AZURE_SUBSCRIPTION_ID" ]; then
    subscription=$(az account show --query "id" -o tsv)
    echo "AZURE_SUBSCRIPTION_ID is not set. Using current subscription ID: $subscription"
else
    subscription="$AZURE_SUBSCRIPTION_ID"
    echo "Using specified subscription ID: $subscription"
fi

# Set the subscription ID
echo "Switching to subscription ID: $subscription"
az account set --subscription "$subscription" || { echo "Failed to set subscription."; exit 1; }

output_file="maintenance_events.json"
temp_file="temp_events.json"

echo "--- Starting Azure Planned Maintenance Event Retrieval ---"
echo "Subscription ID: $subscription"
echo "Output File: $output_file"

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

# Function to parse impact data into a proper JSON object
parse_impact_data() {
    local impact_json=$1
    # Parse the JSON string into a proper JSON object
    echo "$impact_json" | jq -r '.' 2>/dev/null || echo '[]'
}

# Query for planned maintenance events
echo "Fetching planned maintenance events from Azure..."
query="
ServiceHealthResources
| where type =~ 'microsoft.resourcehealth/events'
| extend 
    eventType = tostring(properties.EventType),
    status = tostring(properties.Status),
    description = tostring(properties.Title),
    trackingId = tostring(properties.TrackingId),
    summary = tostring(properties.Summary),
    level = tostring(properties.Level),
    impact = properties.Impact,
    impactStartTime = todatetime(properties.ImpactStartTime),
    impactMitigationTime = todatetime(properties.ImpactMitigationTime)
| where eventType == 'PlannedMaintenance'
| project
    subscriptionId,
    trackingId,
    eventType,
    status,
    summary,
    description,
    level,
    impactStartTime,
    impactMitigationTime,
    id,
    impact
| order by impactStartTime asc
"

echo "Executing query to get maintenance events..."
if ! events_result=$(az graph query -q "$query" --subscriptions "$subscription" -o json 2>/dev/null); then
    echo "ERROR: Failed to retrieve planned maintenance events from Azure." >&2
    echo "[]" > "$output_file"
    exit 1
fi

# Process the results
echo "Processing results..."
processed_events=()
count=$(echo "$events_result" | jq -r '.data | length' 2>/dev/null || echo "0")

echo "Found $count planned maintenance events."

for ((i=0; i<count; i++)); do
    event=$(echo "$events_result" | jq -c ".data[$i]" 2>/dev/null)
    
    # Extract basic event info
    base_event=$(echo "$event" | jq '{
        subscriptionId,
        trackingId,
        eventType,
        status,
        summary,
        description,
        level,
        impactStartTime,
        impactMitigationTime,
        id
    }')
    
    # Process impact data
    impact_json=$(echo "$event" | jq -r '.impact' 2>/dev/null)
    impact_details=$(parse_impact_data "$impact_json" 2>/dev/null)
    
    # Combine base event with parsed impact
    processed_event=$(echo "$base_event" | jq --argjson impact "$impact_details" '
        . + {
            impactDetails: $impact
        }
    ')
    
    processed_events+=("$processed_event")
done

# Combine all events into a JSON array
result_json=$(printf '%s\n' "${processed_events[@]}" | jq -s '.')

# Save to output file
echo "$result_json" > "$output_file"

# Clean up
rm -f "$temp_file" 2>/dev/null || true

echo "Results saved to $output_file"
echo "--- Azure Planned Maintenance Event Retrieval Finished ---"

exit 0