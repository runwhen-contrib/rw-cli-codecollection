#!/usr/bin/env bash
# ---------------------------------------------------------------------------
#  service_bus_resource_health.sh
#
#  PURPOSE:
#    Uses Microsoft Resource Health to fetch the current availability status
#    for a Service Bus namespace and writes it to service_bus_health.json.
#
#  REQUIRED ENV VARS
#    SB_NAMESPACE_NAME    Name of the Service Bus namespace
#    AZ_RESOURCE_GROUP    Resource group containing the namespace
#
#  OPTIONAL ENV VAR
#    AZURE_RESOURCE_SUBSCRIPTION_ID  Subscription to target (defaults to az login context)
# ---------------------------------------------------------------------------

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

set -euo pipefail

HEALTH_OUTPUT="service_bus_health.json"
echo "[]" > "$HEALTH_OUTPUT"

# ---------------------------------------------------------------------------
# 1) Determine subscription ID
# ---------------------------------------------------------------------------
if [[ -z "${AZURE_RESOURCE_SUBSCRIPTION_ID:-}" ]]; then
  subscription=$(az account show --query "id" -o tsv)
  echo "Using current Azure CLI subscription: $subscription"
else
  subscription="$AZURE_RESOURCE_SUBSCRIPTION_ID"
  echo "Using AZURE_RESOURCE_SUBSCRIPTION_ID: $subscription"
fi

az account set --subscription "$subscription"

# ---------------------------------------------------------------------------
# 2) Ensure Microsoft.ResourceHealth provider is registered
# ---------------------------------------------------------------------------
echo "Checking Microsoft.ResourceHealth provider registration…"
reg_state=$(az provider show --namespace Microsoft.ResourceHealth --query "registrationState" -o tsv)

if [[ "$reg_state" != "Registered" ]]; then
  echo "Registering provider…"
  az provider register --namespace Microsoft.ResourceHealth
  # wait (max ~2 min)
  for i in {1..12}; do
    sleep 10
    reg_state=$(az provider show --namespace Microsoft.ResourceHealth --query "registrationState" -o tsv)
    [[ "$reg_state" == "Registered" ]] && break
    echo "  still $reg_state …"
  done
fi

[[ "$reg_state" != "Registered" ]] && {
  echo "ERROR: Microsoft.ResourceHealth provider not registered."
  exit 1
}

# ---------------------------------------------------------------------------
# 3) Validate required env vars
# ---------------------------------------------------------------------------
: "${SB_NAMESPACE_NAME:?Must set SB_NAMESPACE_NAME}"
: "${AZ_RESOURCE_GROUP:?Must set AZ_RESOURCE_GROUP}"

# ---------------------------------------------------------------------------
# 4) Query Resource Health
# ---------------------------------------------------------------------------
echo "Retrieving Resource Health status for $SB_NAMESPACE_NAME …"

az rest --method get \
  --url \
"https://management.azure.com/subscriptions/${subscription}/resourceGroups/${AZ_RESOURCE_GROUP}/providers/Microsoft.ServiceBus/namespaces/${SB_NAMESPACE_NAME}/providers/Microsoft.ResourceHealth/availabilityStatuses/current?api-version=2023-07-01-preview" \
  -o json > "$HEALTH_OUTPUT" || {
    echo "Failed to retrieve health status."
    exit 1
  }

echo "Health status written to $HEALTH_OUTPUT"
cat "$HEALTH_OUTPUT"
