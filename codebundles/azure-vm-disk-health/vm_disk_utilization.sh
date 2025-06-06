#!/bin/bash
# Script to check disk utilization on Azure VMs
#set -x
# Get parameters from environment variables
SUBSCRIPTION_ID=${AZURE_SUBSCRIPTION_ID}
RESOURCE_GROUP=${AZ_RESOURCE_GROUP}
VM_NAME=${VM_NAME:-""}
THRESHOLD=${DISK_THRESHOLD:-60}

# Initialize output directory
#mkdir -p "${OUTPUT_DIR}"
ISSUES_FILE="issues.json"
echo '{"issues":[]}' > "${ISSUES_FILE}"

# Function to add an issue
add_issue() {
    local title="$1"
    local severity="$2"
    local next_step="$3"
    local details="$4"
    
    # Escape JSON special characters
    details=$(echo "$details" | sed 's/"/\\"/g' | sed ':a;N;$!ba;s/\n/\\n/g')
    
    # Add issue to the issues file
    local issue="{\"title\":\"$title\",\"severity\":$severity,\"next_step\":\"$next_step\",\"details\":\"$details\"}"
    local temp_file="temp.json"
    jq ".issues += [$issue]" "${ISSUES_FILE}" > "${temp_file}" && mv "${temp_file}" "${ISSUES_FILE}"
}

echo "Checking disk utilization (Warning threshold: ${THRESHOLD}%)"
echo "----------------------------------------------------------------------"

# Set subscription
az account set --subscription "${SUBSCRIPTION_ID}"

# Get VMs based on parameters
if [ -n "${VM_NAME}" ]; then
    # Check specific VM
    vms=$(az vm list --resource-group "${RESOURCE_GROUP}" --query "[?name=='${VM_NAME}'].{name:name, resourceGroup:resourceGroup}" -o json)
else
    # Check all VMs in the resource group
    vms=$(az vm list --resource-group "${RESOURCE_GROUP}" --query "[].{name:name, resourceGroup:resourceGroup}" -o json)
fi

# Check if there are any VMs
if [ "$(echo $vms | jq length)" -eq "0" ]; then
    echo "No VMs found in resource group ${RESOURCE_GROUP}"
    exit 0
fi

# Loop through each VM
echo "$vms" | jq -c '.[]' | while read -r vm; do
    vm_name=$(echo $vm | jq -r '.name')
    resource_group=$(echo $vm | jq -r '.resourceGroup')
    
    echo "Checking VM: $vm_name in resource group: $resource_group"
    
    # Get VM status
    vm_status=$(az vm get-instance-view -g $resource_group -n $vm_name --query "instanceView.statuses[?starts_with(code,'PowerState/')].displayStatus" -o tsv)
    
    if [[ "$vm_status" != *"running"* ]]; then
        echo "  VM is not running (status: $vm_status). Skipping..."
        continue
    fi
    
    # Run disk usage command on the VM
    echo "  Disk utilization:"
    disk_output=$(az vm run-command invoke \
        --resource-group $resource_group \
        --name $vm_name \
        --command-id RunShellScript \
        --scripts "df -h | grep -v tmpfs | grep -v cdrom | grep -v loop" \
        --query "value[0].message" -o tsv)
    
    # Display the output
    echo "$disk_output"
    
    # Check for high disk usage
    high_usage_disks=""
    while read -r line; do
        # Skip header line
        if [[ "$line" == *"Filesystem"* ]]; then
            continue
        fi
        
        # Extract usage percentage
        usage_percent=$(echo "$line" | awk '{print $5}' | sed 's/%//')
        filesystem=$(echo "$line" | awk '{print $1}')
        mount_point=$(echo "$line" | awk '{print $6}')
        
        # Check if usage is above threshold
        if [ -n "$usage_percent" ] && [ "$usage_percent" -ge "$THRESHOLD" ]; then
            high_usage_disks="${high_usage_disks}${filesystem} (${mount_point}): ${usage_percent}%\n"
        fi
    done <<< "$disk_output"
    
    # Create issue if high disk usage detected
    if [ -n "$high_usage_disks" ]; then
        issue_title="High Disk Usage Detected on VM ${vm_name}"
        issue_severity=2
        issue_next_step="Consider cleaning up disk space or expanding the disk."
        issue_details="The following disks have usage above ${THRESHOLD}%:\n${high_usage_disks}\nFull disk report:\n${disk_output}"
        add_issue "$issue_title" "$issue_severity" "$issue_next_step" "$issue_details"
    fi
    
    echo ""
done

echo "Disk utilization check completed."