#!/bin/bash
# vm_disk_utilization.sh

SUBSCRIPTION_ID=${AZURE_SUBSCRIPTION_ID}
RESOURCE_GROUP=${AZ_RESOURCE_GROUP}
VM_NAME=${VM_NAME:-""}
OUTPUT_FILE="vm-disk-utilization.json"

az account set --subscription "${SUBSCRIPTION_ID}"

if [ -n "${VM_NAME}" ]; then
    vms=$(az vm list --resource-group "${RESOURCE_GROUP}" --query "[?name=='${VM_NAME}'].{name:name, resourceGroup:resourceGroup}" -o json)
else
    vms=$(az vm list --resource-group "${RESOURCE_GROUP}" --query "[].{name:name, resourceGroup:resourceGroup}" -o json)
fi

if [ "$(echo $vms | jq length)" -eq "0" ]; then
    echo "No VMs found in resource group ${RESOURCE_GROUP}"
    exit 0
fi

results=()

echo "$vms" | jq -c '.[]' | while read -r vm; do
    vm_name=$(echo $vm | jq -r '.name')
    resource_group=$(echo $vm | jq -r '.resourceGroup')

    vm_status=$(az vm get-instance-view -g $resource_group -n $vm_name \
        --query "instanceView.statuses[?starts_with(code,'PowerState/')].displayStatus" -o tsv)

    if [[ "$vm_status" != *"running"* ]]; then
        echo "Skipping VM $vm_name (status: $vm_status)"
        continue
    fi

    echo "Checking disk utilization on $vm_name..."
    disk_output=$(az vm run-command invoke \
        --resource-group "$resource_group" \
        --name "$vm_name" \
        --command-id RunShellScript \
        --scripts "df -h")

    # Add result as a JSON object to the results array
    results+=("$(jq -n --arg name "$vm_name" --argjson output "$(echo "$disk_output" | jq '.')" \
        '{vm_name: $name, disk_output: $output}')")
done

# Output the results array as a JSON array to the output file
printf '%s\n' "${results[@]}" | jq -s '.' > "$OUTPUT_FILE"
