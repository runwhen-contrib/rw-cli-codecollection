#!/bin/bash
# vm_memory_check.sh

SUBSCRIPTION_ID=${AZURE_SUBSCRIPTION_ID}
RESOURCE_GROUP=${AZ_RESOURCE_GROUP}
VM_NAME=${VM_NAME:-""}
OUTPUT_FILE="vm-memory-check.json"

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

    echo "Checking memory usage on $vm_name..."
    memory_output=$(az vm run-command invoke \
        --resource-group "$resource_group" \
        --name "$vm_name" \
        --command-id RunShellScript \
        --scripts "free -m")

    results+=("$(jq -n --arg name "$vm_name" --argjson output "$(echo "$memory_output" | jq '.')" \
        '{vm_name: $name, memory_output: $output}')")
done

printf '%s\n' "${results[@]}" | jq -s '.' > "$OUTPUT_FILE"