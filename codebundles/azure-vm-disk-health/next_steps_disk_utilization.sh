#!/bin/bash
# next_steps_disk_utilization.sh
set -x

THRESHOLD=${DISK_THRESHOLD:-70}  # Default threshold of 80%
VM_NAME=${VM_NAME:-"unknown"}
STDOUT_FILE="/tmp/vm_disk_stdout.txt"

cat /tmp/vm_disk_stdout.txt

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
        issue_title="High Disk Usage on VM `${VM_NAME}`"
        issue_severity=2
        issue_expected="Disk usage should be below ${THRESHOLD}% on VM `${VM_NAME}`"
        issue_actual="Disk usage is at ${use_percent}% on filesystem ${filesystem} (${mount_point}) on VM `${VM_NAME}`"
        issue_details="Filesystem ${filesystem} mounted at ${mount_point} is at ${use_percent}% capacity (${used} used out of ${size}).\nThis exceeds the threshold of ${THRESHOLD}%."
        issue_next_steps="1. Clean up unnecessary files on the filesystem\n2. Consider expanding the disk\n3. Implement disk usage monitoring\n4. Review application logs for disk-intensive operations"
        
        add_issue "$issue_title" "$issue_severity" "$issue_expected" "$issue_actual" "$issue_details" "$issue_next_steps"
    fi
done  < "$STDOUT_FILE"

# Check if any issues were found
issues_count=$(jq '. | length' "${ISSUES_FILE}")
if [ "$issues_count" -eq 0 ]; then
    echo "No disk utilization issues found for VM ${VM_NAME}."
fi

rm -f "${STDOUT_FILE}"