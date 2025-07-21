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
        total_mem=$(echo "$line" | awk '{print $2}')
        used_mem=$(echo "$line" | awk '{print $3}')
        
        if [[ "$total_mem" =~ ^[0-9]+$ ]] && [[ "$used_mem" =~ ^[0-9]+$ ]] && [ "$total_mem" -gt 0 ]; then
            mem_percent=$(( (used_mem * 100) / total_mem ))
            
            # Convert to GB for better readability if > 1024 MB
            if [ "$total_mem" -gt 1024 ]; then
                total_gb=$(awk "BEGIN {printf \"%.1f\", $total_mem/1024}")
                used_gb=$(awk "BEGIN {printf \"%.1f\", $used_mem/1024}")
                free_mem=$(( total_mem - used_mem ))
                free_gb=$(awk "BEGIN {printf \"%.1f\", $free_mem/1024}")
                mem_display="${used_gb}GB used out of ${total_gb}GB total (${free_gb}GB free)"
            else
                free_mem=$(( total_mem - used_mem ))
                mem_display="${used_mem}MB used out of ${total_mem}MB total (${free_mem}MB free)"
            fi
            
            if [ "$mem_percent" -ge "$THRESHOLD" ]; then
                add_issue \
                    "Virtual Machine \`${VM_NAME}\` (RG: \`${AZ_RESOURCE_GROUP}\`) has high memory usage of ${mem_percent}% (Subscription: \`${AZURE_SUBSCRIPTION_NAME}\`)" \
                    2 \
                    "Memory usage should be below ${THRESHOLD}% on VM \`${VM_NAME}\` in Resource Group \`${AZ_RESOURCE_GROUP}\`" \
                    "Memory usage is at ${mem_percent}% (${mem_display}) on VM \`${VM_NAME}\` in Resource Group \`${AZ_RESOURCE_GROUP}\`" \
                    "Memory usage is ${mem_percent}% - ${mem_display}.\nThis exceeds the threshold of ${THRESHOLD}%.\nResource Group: \`${AZ_RESOURCE_GROUP}\`\nSubscription: \`${AZURE_SUBSCRIPTION_NAME}\`" \
                    "Investigate memory usage on VM \`${VM_NAME}\` in resource group \`${AZ_RESOURCE_GROUP}\` (subscription: \`${AZURE_SUBSCRIPTION_NAME}\`)\nIdentify memory-intensive processes\nConsider increasing VM memory\nReview application memory usage patterns\nImplement memory monitoring"
            fi
        fi
    fi
done < "$STDOUT_FILE"

issues_count=$(jq '. | length' "${ISSUES_FILE}")
if [ "$issues_count" -eq 0 ]; then
    echo "No memory utilization issues found for VM ${VM_NAME}."
fi

rm -f "${STDOUT_FILE}"