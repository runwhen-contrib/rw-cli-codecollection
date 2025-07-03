#!/bin/bash
# next_steps_uptime.sh

PARSED_FILE="$1"
THRESHOLD=${UPTIME_THRESHOLD:-30}  # Default threshold of 30 days
ISSUES_FILE="vm_uptime_issues.json"
VM_NAME=${VM_NAME:-"unknown"}

# Initialize issues array
echo '[]' > "${ISSUES_FILE}"

add_issue() {
    local title="$1"
    local severity="$2"
    local next_step="$3"
    local details="$4"

    details=$(echo "$details" | sed 's/"/\\"/g' | sed ':a;N;$!ba;s/\n/\\n/g')
    local issue="{\"title\":\"$title\",\"severity\":$severity,\"next_step\":\"$next_step\",\"details\":\"$details\"}"
    jq ". += [$issue]" "${ISSUES_FILE}" > temp.json && mv temp.json "${ISSUES_FILE}"
}

stdout=$(jq -r '.value[0].message' "$PARSED_FILE" 2>/dev/null)
stderr=$(jq -r '.error' "$PARSED_FILE" 2>/dev/null)

if [ -n "$stderr" ] && [ "$stderr" != "null" ]; then
    echo "Error detected: $stderr"
    add_issue "Error checking uptime for VM ${VM_NAME}" 3 "Check VM access permissions and connectivity" "$stderr"
    exit 1
fi

# Extract uptime value (days)
uptime_days=$(echo "$stdout" | awk '{print $1}')

if [ -z "$uptime_days" ]; then
    add_issue "Failed to retrieve uptime for VM ${VM_NAME}" 3 "Verify VM is running and accessible" "No uptime data returned from VM"
    exit 1
fi

# Round to 2 decimal places
uptime_days=$(printf "%.2f" "$uptime_days")

# Check if uptime exceeds threshold
if (( $(echo "$uptime_days > $THRESHOLD" | bc -l) )); then
    issue_title="High Uptime Detected on VM ${VM_NAME}"
    issue_severity=2
    issue_next_step="Consider scheduling a maintenance window to reboot this VM."
    issue_details="VM ${VM_NAME} has been running for ${uptime_days} days, which exceeds the threshold of ${THRESHOLD} days.\nRegular reboots are recommended to apply security patches and maintain system health."
    add_issue "$issue_title" "$issue_severity" "$issue_next_step" "$issue_details"
else
    echo "VM ${VM_NAME} uptime is ${uptime_days} days, which is within acceptable limits."
fi