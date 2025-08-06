#!/bin/bash
# next_steps_patch_time.sh

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