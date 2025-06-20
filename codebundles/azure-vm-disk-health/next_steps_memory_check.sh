#!/bin/bash
# next_steps_memory_check.sh

PARSED_FILE="$1"
THRESHOLD=${MEMORY_THRESHOLD:-80}  # Default threshold of 80%
ISSUES_FILE="memory_usage_issues.json"
VM_NAME=${VM_NAME:-"unknown"}

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

stdout=$(jq -r '.value[0].message' "$PARSED_FILE" 2>/dev/null)
stderr=$(jq -r '.error' "$PARSED_FILE" 2>/dev/null)

if [ -n "$stderr" ] && [ "$stderr" != "null" ]; then
    echo "Error detected: $stderr"
    add_issue "Error checking memory usage for VM ${VM_NAME}" 3 "VM should be accessible for memory checks" "Error accessing VM ${VM_NAME}" "$stderr" "Check VM access permissions and connectivity"
    exit 1
fi

# Parse the memory usage output
memory_usage=$(echo "$stdout" | tr -d '\r\n')

# Skip if memory_usage is not a number
if ! [[ "$memory_usage" =~ ^[0-9]+$ ]]; then
    echo "Invalid memory usage value: $memory_usage"
    add_issue "Invalid memory usage data for VM `${VM_NAME}`" 3 "Memory usage should be a valid percentage" "Received invalid memory usage data: $memory_usage" "The memory usage check returned an invalid value. This could indicate a problem with the VM or the monitoring script." "1. Verify VM is running\n2. Check VM agent status\n3. Try running memory check manually"
    exit 1
fi

# Check if memory usage exceeds threshold
if [ "$memory_usage" -ge "$THRESHOLD" ]; then
    issue_title="High Memory Usage on VM `${VM_NAME}`"
    issue_severity=2
    issue_expected="Memory usage should be below ${THRESHOLD}% on VM `${VM_NAME}`"
    issue_actual="Memory usage is at ${memory_usage}% on VM `${VM_NAME}`"
    issue_details="Memory usage on VM ${VM_NAME} is at ${memory_usage}%.\nThis exceeds the threshold of ${THRESHOLD}%."
    issue_next_steps="1. Identify memory-intensive processes using 'top' or 'ps'\n2. Check for memory leaks in applications\n3. Consider increasing VM memory allocation\n4. Implement memory usage monitoring and alerts"
    
    add_issue "$issue_title" "$issue_severity" "$issue_expected" "$issue_actual" "$issue_details" "$issue_next_steps"
fi

# Check if any issues were found
issues_count=$(jq '. | length' "${ISSUES_FILE}")
if [ "$issues_count" -eq 0 ]; then
    echo "No memory usage issues found for VM ${VM_NAME}."
fi