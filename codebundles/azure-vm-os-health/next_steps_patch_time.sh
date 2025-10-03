#!/bin/bash
# next_steps_patch_time.sh

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

VM_NAME=${VM_NAME:-"unknown"}
# Accept file path as first argument, or use default relative path
STDOUT_FILE="${1:-vm_patch_stdout.txt}"
ISSUES_FILE="patch_issues.json"

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

# Parse the patch output
patch_content=$(cat "$STDOUT_FILE")

# Check if system is up to date
if echo "$patch_content" | grep -q "System is up to date"; then
    echo "No patch issues found for VM ${VM_NAME} - system is up to date."
elif echo "$patch_content" | grep -q "Unable to determine patch status"; then
    # Unknown/unsupported OS
    add_issue \
        "Virtual Machine \`${VM_NAME}\` (RG: \`${AZ_RESOURCE_GROUP}\`) has unknown patch status (Subscription: \`${AZURE_SUBSCRIPTION_NAME}\`)" \
        3 \
        "Patch status should be determinable on VM \`${VM_NAME}\` in Resource Group \`${AZ_RESOURCE_GROUP}\`" \
        "Unable to determine patch status - unsupported or unknown OS on VM \`${VM_NAME}\` in Resource Group \`${AZ_RESOURCE_GROUP}\`" \
        "$patch_content\nResource Group: \`${AZ_RESOURCE_GROUP}\`\nSubscription: \`${AZURE_SUBSCRIPTION_NAME}\`" \
        "Check OS type and package manager on VM \`${VM_NAME}\` in resource group \`${AZ_RESOURCE_GROUP}\`"
elif echo "$patch_content" | grep -q "packages available for upgrade"; then
    # Extract package count
    package_count=$(echo "$patch_content" | grep "Pending Updates:" | sed 's/.*: \([0-9]*\) packages.*/\1/')
    package_manager=$(echo "$patch_content" | grep "Package Manager:" | cut -d':' -f2 | xargs)
    
    # Determine severity based on package count - patches are recommendations (severity 4)
    severity=4
    
    add_issue \
        "Virtual Machine \`${VM_NAME}\` (RG: \`${AZ_RESOURCE_GROUP}\`) has ${package_count} pending OS patches (Subscription: \`${AZURE_SUBSCRIPTION_NAME}\`)" \
        $severity \
        "All security patches should be applied on VM \`${VM_NAME}\` in Resource Group \`${AZ_RESOURCE_GROUP}\`" \
        "${package_count} pending package updates detected on VM \`${VM_NAME}\` in Resource Group \`${AZ_RESOURCE_GROUP}\` using ${package_manager}" \
        "Package Manager: ${package_manager}\nPending Updates: ${package_count} packages\n\n${patch_content}\n\nResource Group: \`${AZ_RESOURCE_GROUP}\`\nSubscription: \`${AZURE_SUBSCRIPTION_NAME}\`" \
        "Apply ${package_count} pending updates on VM \`${VM_NAME}\` in resource group \`${AZ_RESOURCE_GROUP}\`"
fi

issues_count=$(jq '. | length' "${ISSUES_FILE}")
if [ "$issues_count" -eq 0 ]; then
    echo "No patch issues found for VM ${VM_NAME}."
fi

rm -f "${STDOUT_FILE}"