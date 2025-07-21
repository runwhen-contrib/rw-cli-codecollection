#!/bin/bash
# next_steps_uptime.sh

THRESHOLD=${UPTIME_THRESHOLD:-7}
VM_NAME=${VM_NAME:-"unknown"}
STDOUT_FILE="/tmp/vm_uptime_stdout.txt"
ISSUES_FILE="uptime_issues.json"

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

while IFS= read -r line; do
    # Look for the decimal days line
    if [[ "$line" =~ "Uptime (decimal days):" ]]; then
        uptime_days=$(echo "$line" | sed 's/.*: \([0-9]*\.[0-9]*\).*/\1/')
        uptime_days_int=$(echo "$uptime_days" | cut -d'.' -f1)
        
        # Get the human-readable uptime from the previous lines stored in temp
        uptime_human=$(grep "System Uptime:" "$STDOUT_FILE" | sed 's/System Uptime: //')
        
        if (( $(echo "$uptime_days >= $THRESHOLD" | bc -l) )); then
            add_issue \
                "Virtual Machine \`${VM_NAME}\` (RG: \`${AZ_RESOURCE_GROUP}\`) has been running for ${uptime_days} days (Subscription: \`${AZURE_SUBSCRIPTION_NAME}\`)" \
                2 \
                "Uptime should be less than ${THRESHOLD} days on VM \`${VM_NAME}\` in Resource Group \`${AZ_RESOURCE_GROUP}\`" \
                "Uptime is ${uptime_days} days (${uptime_human}) on VM \`${VM_NAME}\` in Resource Group \`${AZ_RESOURCE_GROUP}\`" \
                "System uptime is ${uptime_human} (${uptime_days} days total).\nThis exceeds the threshold of ${THRESHOLD} days.\nResource Group: \`${AZ_RESOURCE_GROUP}\`\nSubscription: \`${AZURE_SUBSCRIPTION_NAME}\`" \
                "Consider scheduling a reboot for VM \`${VM_NAME}\` in resource group \`${AZ_RESOURCE_GROUP}\` (subscription: \`${AZURE_SUBSCRIPTION_NAME}\`)\nCheck for pending updates\nReview system logs for issues"
        fi
        break
    fi
done < "$STDOUT_FILE"

issues_count=$(jq '. | length' "${ISSUES_FILE}")
if [ "$issues_count" -eq 0 ]; then
    echo "No uptime issues found for VM ${VM_NAME}."
fi

rm -f "${STDOUT_FILE}"
