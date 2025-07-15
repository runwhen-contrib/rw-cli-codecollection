#!/bin/bash
# next_steps_patch_time.sh

VM_NAME=${VM_NAME:-"unknown"}
STDOUT_FILE="/tmp/vm_patch_stdout.txt"
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

patch_lines=$(grep -v -e '^$' -e 'Unknown OS' "$STDOUT_FILE" | wc -l)

if [ "$patch_lines" -gt 0 ]; then
    details=$(cat "$STDOUT_FILE")
    add_issue \
        "Pending OS Patches on VM ${VM_NAME}" \
        2 \
        "All security patches should be applied on VM ${VM_NAME} in resource group ${AZ_RESOURCE_GROUP} (subscription: ${AZURE_SUBSCRIPTION_ID})" \
        "Pending patches detected on VM ${VM_NAME} in resource group ${AZ_RESOURCE_GROUP} (subscription: ${AZURE_SUBSCRIPTION_ID})" \
        "$details\nResource Group: ${AZ_RESOURCE_GROUP}\nSubscription: ${AZURE_SUBSCRIPTION_ID}" \
        "1. Review and apply pending updates on VM ${VM_NAME} in resource group ${AZ_RESOURCE_GROUP} (subscription: ${AZURE_SUBSCRIPTION_ID})\n2. Reboot if required\n3. Ensure regular patching schedule"
fi

issues_count=$(jq '. | length' "${ISSUES_FILE}")
if [ "$issues_count" -eq 0 ]; then
    echo "No patch issues found for VM ${VM_NAME}."
fi

rm -f "${STDOUT_FILE}"