#!/bin/bash

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

subscription_id="$AZURE_RESOURCE_SUBSCRIPTION_ID"
resource_group="$AZURE_RESOURCE_GROUP"

json_output='{"keyVaults":['
first=true

for kv in $(az keyvault list -g "$resource_group" --subscription "$subscription_id" --query "[].name" -o tsv); do
  
  # Get both properties in single command and parse with jq
  kv_properties=$(az keyvault show --name "$kv" --subscription "$subscription_id"  -o json)
  # echo $kv_properties
  soft_delete=$(echo "$kv_properties" | jq -r '.properties.enableSoftDelete')
  purge_protection=$(echo "$kv_properties" | jq -r '.properties.enablePurgeProtection')
  resource_id=$(echo "$kv_properties" | jq -r '.id')
  
  # Build Azure resource URL using the resource ID
  resource_url="https://portal.azure.com/#@/resource${resource_id}/overview"

  # Convert empty values to "Unknown" for safety
  soft_delete=${soft_delete:-"null"}
  purge_protection=${purge_protection:-"null"}
  resource_url=${resource_url:-"null"}

  # Append to JSON array
  if [ "$first" = true ]; then
    first=false
  else
    json_output+=','
  fi

  json_output+="{\"kv_name\":\"$kv\",\"soft_delete\":\"$soft_delete\",\"purge_protection\":\"$purge_protection\",\"resource_url\":\"$resource_url\"}"
done

json_output+=']}'
echo "$json_output"
