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
    # /proc/uptime gives seconds as first value
    if [[ "$line" =~ ^[0-9]+\.[0-9]+ ]]; then
        uptime_sec=$(echo "$line" | awk '{print $1}')
        uptime_days=$(awk "BEGIN {printf \"%.2f\", $uptime_sec/86400}")
        uptime_days_int=$(awk "BEGIN {printf \"%d\", $uptime_sec/86400}")
        if (( $(echo "$uptime_days >= $THRESHOLD" | bc -l) )); then
            add_issue \
                "High Uptime on VM ${VM_NAME}" \
                2 \
                "Uptime should be less than ${THRESHOLD} days on VM ${VM_NAME} in resource group ${AZ_RESOURCE_GROUP} (subscription: ${AZURE_SUBSCRIPTION_NAME})" \
                "Uptime is ${uptime_days} days on VM ${VM_NAME} in resource group ${AZ_RESOURCE_GROUP} (subscription: ${AZURE_SUBSCRIPTION_NAME})" \
                "System uptime is ${uptime_days} days (${uptime_sec} seconds).\nResource Group: ${AZ_RESOURCE_GROUP}\nSubscription: ${AZURE_SUBSCRIPTION_NAME}" \
                "Consider scheduling a reboot for VM ${VM_NAME} in resource group ${AZ_RESOURCE_GROUP} (subscription: ${AZURE_SUBSCRIPTION_NAME})\nCheck for pending updates\nReview system logs for issues"
        fi
    fi
done < "$STDOUT_FILE"

issues_count=$(jq '. | length' "${ISSUES_FILE}")
if [ "$issues_count" -eq 0 ]; then
    echo "No uptime issues found for VM ${VM_NAME}."
fi

rm -f "${STDOUT_FILE}"
