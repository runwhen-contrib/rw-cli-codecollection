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

THRESHOLD=${DISK_THRESHOLD:-85}  # Default threshold of 85% to match template configuration
VM_NAME=${VM_NAME:-"unknown"}
# Accept file path as first argument, or use default relative path
STDOUT_FILE="${1:-vm_disk_stdout.txt}"

ISSUES_FILE="disk_utilization_issues.json"

# Initialize issues array
echo '[]' > "${ISSUES_FILE}"

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
    jq ". += [$issue]" "${ISSUES_FILE}" > temp.json && mv temp.json "${ISSUES_FILE}"
}

# Use the STDOUT variable directly
while IFS= read -r line; do
    # Skip header lines and empty lines
    if [[ "$line" =~ ^Filesystem|^$|^tmpfs|^udev|^none|^/dev/loop ]]; then
        continue
    fi

    # Extract filesystem, size, used, available, percentage used, and mount point
    filesystem=$(echo "$line" | awk '{print $1}')
    size=$(echo "$line" | awk '{print $2}')
    used=$(echo "$line" | awk '{print $3}')
    avail=$(echo "$line" | awk '{print $4}')
    use_percent=$(echo "$line" | awk '{print $5}' | tr -d '%')
    mount_point=$(echo "$line" | awk '{print $6}')

    # Skip if use_percent is not a number
    if ! [[ "$use_percent" =~ ^[0-9]+$ ]]; then
        continue
    fi

    # Check if disk usage exceeds threshold
    if [ "$use_percent" -ge "$THRESHOLD" ]; then
        # Calculate available space for better context
        avail_clean=$(echo "$avail" | sed 's/[^0-9.]*//g')
        size_clean=$(echo "$size" | sed 's/[^0-9.]*//g')
        used_clean=$(echo "$used" | sed 's/[^0-9.]*//g')
        
        issue_title="Virtual Machine \`${VM_NAME}\` (RG: \`${AZ_RESOURCE_GROUP}\`) has high disk usage of ${use_percent}% (Subscription: \`${AZURE_SUBSCRIPTION_NAME}\`)"
        issue_severity=2
        issue_expected="Disk usage should be below ${THRESHOLD}% on VM \`${VM_NAME}\` in Resource Group \`${AZ_RESOURCE_GROUP}\`"
        issue_actual="Disk usage is at ${use_percent}% on filesystem ${filesystem} (${mount_point}) - ${used} used out of ${size} total (${avail} available) on VM \`${VM_NAME}\` in Resource Group \`${AZ_RESOURCE_GROUP}\`"
        issue_details="Filesystem: ${filesystem}\nMount Point: ${mount_point}\nDisk Usage: ${use_percent}%\nUsed Space: ${used}\nTotal Space: ${size}\nAvailable Space: ${avail}\nThis exceeds the threshold of ${THRESHOLD}%.\nResource Group: \`${AZ_RESOURCE_GROUP}\`\nSubscription: \`${AZURE_SUBSCRIPTION_NAME}\`"
        issue_next_steps="Clean up disk space on VM \`${VM_NAME}\` filesystem ${filesystem} (${mount_point}) in resource group \`${AZ_RESOURCE_GROUP}\`"
        
        add_issue "$issue_title" "$issue_severity" "$issue_expected" "$issue_actual" "$issue_details" "$issue_next_steps"
    fi
done  < "$STDOUT_FILE"

# Check if any issues were found
issues_count=$(jq '. | length' "${ISSUES_FILE}")
if [ "$issues_count" -eq 0 ]; then
    echo "No disk utilization issues found for VM ${VM_NAME}."
fi

rm -f "${STDOUT_FILE}"