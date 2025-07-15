#!/bin/bash
# next_steps_memory_check.sh

THRESHOLD=${MEMORY_THRESHOLD:-80}
VM_NAME=${VM_NAME:-"unknown"}
STDOUT_FILE="/tmp/vm_mem_stdout.txt"
ISSUES_FILE="memory_utilization_issues.json"

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

RESOURCE_GROUP=${AZ_RESOURCE_GROUP:-"unknown"}
SUBSCRIPTION_ID=${AZURE_SUBSCRIPTION_ID:-"unknown"}

while IFS= read -r line; do
    if [[ "$line" =~ ^Mem: ]]; then
        total=$(echo "$line" | awk '{print $2}')
        used=$(echo "$line" | awk '{print $3}')
        if [[ -n "$total" && -n "$used" && "$total" -gt 0 ]]; then
            percent=$(awk "BEGIN {printf \"%.0f\", ($used/$total)*100}")
            if [ "$percent" -ge "$THRESHOLD" ]; then
                add_issue \
                    "High Memory Usage on VM ${VM_NAME}" \
                    2 \
                    "Memory usage should be below ${THRESHOLD}% on VM ${VM_NAME} in resource group ${AZ_RESOURCE_GROUP} (subscription: ${AZURE_SUBSCRIPTION_ID})" \
                    "Memory usage is at ${percent}% on VM ${VM_NAME} in resource group ${AZ_RESOURCE_GROUP} (subscription: ${AZURE_SUBSCRIPTION_ID})" \
                    "Memory usage is ${used}MB out of ${total}MB (${percent}%).\nResource Group: ${AZ_RESOURCE_GROUP}\nSubscription: ${AZURE_SUBSCRIPTION_ID}" \
                    "1. Investigate memory-intensive processes on VM ${VM_NAME} in resource group ${AZ_RESOURCE_GROUP} (subscription: ${AZURE_SUBSCRIPTION_ID})\n2. Consider scaling up memory\n3. Check for memory leaks\n4. Restart services if needed"
            fi
        fi
    fi
done < "$STDOUT_FILE"

issues_count=$(jq '. | length' "${ISSUES_FILE}")
if [ "$issues_count" -eq 0 ]; then
    echo "No memory utilization issues found for VM ${VM_NAME}."
fi

rm -f "${STDOUT_FILE}"