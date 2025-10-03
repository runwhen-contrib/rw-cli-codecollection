#!/bin/bash

# Debug mode removed
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

SUBSCRIPTION_ID=${AZURE_SUBSCRIPTION_ID:-}
RESOURCE_GROUP=${AZ_RESOURCE_GROUP:-}
ACR_NAME=${ACR_NAME:-}
USAGE_THRESHOLD=${USAGE_THRESHOLD:-80}

ISSUES_FILE="storage_usage_issues.json"
echo '[]' > "$ISSUES_FILE"

add_issue() {
  local title="$1"
  local severity="$2"
  local expected="$3"
  local actual="$4"
  local details="$5"
  local next_steps="$6"
  details=$(echo "$details" | sed 's/"/\\"/g' | sed ':a;N;$!ba;s/\n/\\n/g')
  next_steps=$(echo "$next_steps" | sed 's/"/\\"/g' | sed ':a;N;$!ba;s/\n/\\n/g')
  local issue="{\"title\":\"$title\",\"severity\":$severity,\"expected\":\"$expected\",\"actual\":\"$actual\",\"details\":\"$details\",\"next_steps\":\"$next_steps\"}"
  jq ". += [${issue}]" "$ISSUES_FILE" > temp.json && mv temp.json "$ISSUES_FILE"
}

usage=$(az acr show-usage --name "$ACR_NAME" --subscription "$SUBSCRIPTION_ID" -o json 2>usage_err.log)
if [ $? -ne 0 ]; then
  error_details=$(cat usage_err.log 2>/dev/null || echo "Unknown error occurred")
  add_issue "Failed to get storage usage" 4 "Registry storage usage info should be retrievable" "Command failed" "Error retrieving storage usage: $error_details" "Check if ACR \`$ACR_NAME\` and subscription \`$SUBSCRIPTION_ID\` exist and you have access in resource group \`$RESOURCE_GROUP\`"
  rm -f usage_err.log
else
  used=$(echo "$usage" | jq -r '.value[] | select(.name=="Size") | .currentValue')
  quota=$(echo "$usage" | jq -r '.value[] | select(.name=="Size") | .limit')
  percent=$(echo "scale=2; ($used/$quota)*100" | bc)
  if (( $(echo "$percent > $USAGE_THRESHOLD" | bc -l) )); then
    add_issue "High storage usage" 3 "Usage below ${USAGE_THRESHOLD}%" "Usage at $percent%" "Storage usage is at $percent% which exceeds the threshold of ${USAGE_THRESHOLD}%. Used: $used bytes, Quota: $quota bytes" "Consider cleaning unused images in ACR \`$ACR_NAME\` or increase storage quota for resource group \`$RESOURCE_GROUP\`"
  fi
  rm -f usage_err.log
fi

# Output the JSON file content to stdout for Robot Framework
cat "$ISSUES_FILE"
