#!/bin/bash

# ENV:
# AZ_USERNAME
# AZ_SECRET_VALUE
# AZ_SUBSCRIPTION
# AZ_TENANT
# VMSCALESET
# AZ_RESOURCE_GROUP

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


az vmss show --name $VMSCALESET --resource-group $AZ_RESOURCE_GROUP

resource_id=$(az vmss show --resource-group $AZ_RESOURCE_GROUP --name $VMSCALESET --query id -o tsv)
echo "Scanning configuration of resource $resource_id"
prowler azure --az-cli-auth --service vm --output-directory /tmp/prowler --output-filename prowler_azure_scan > /dev/null
report_json=$(cat /tmp/prowler/prowler_azure_scan.ocsf.json)
report_csv=$(cat /tmp/prowler/prowler_azure_scan.csv)
report=()
ok=0
for entry in $(echo "$report_json" | jq -r '.[] | @base64'); do
    _jq() {
        echo ${entry} | base64 --decode | jq -r ${1}
    }
    status_code=$(_jq '.status_code')
    if [ "$status_code" != "PASS" ] && [ "$(_jq '.resources[].uid')" == "$resource_id" ]; then
      resource_name=$(_jq '.resources[].uid')
      status_details=$(_jq '.status_details')
      risk_details=$(_jq '.risk_details')
      report+=("--------------------")
      report+=("Resource Name: $resource_name")
      report+=("Status Code: $status_code")
      report+=("Status Details: $status_details")
      report+=("Risk Details: $risk_details")
      report+=(" ")
      report+=(" ")
      ok=1
    fi
done
if [ $ok -eq 0 ]; then
  echo "No issues found in the scan"
else
  echo "Issues found in the scan related to resource $resource_id"
  echo -e "${report[@]}"
fi
exit $ok