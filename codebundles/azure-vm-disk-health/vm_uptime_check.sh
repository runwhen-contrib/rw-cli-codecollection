#!/bin/bash
# invoke_disk_usage.sh

SUBSCRIPTION_ID=${AZURE_SUBSCRIPTION_ID}
RESOURCE_GROUP=${AZ_RESOURCE_GROUP}
VM_NAME=${VM_NAME:-""}
OUTPUT_DIR="invoke_outputs"
mkdir -p "$OUTPUT_DIR"

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

echo "$vms" | jq -c '.[]' | while read -r vm; do
    vm_name=$(echo $vm | jq -r '.name')
    resource_group=$(echo $vm | jq -r '.resourceGroup')

    vm_status=$(az vm get-instance-view -g $resource_group -n $vm_name \
        --query "instanceView.statuses[?starts_with(code,'PowerState/')].displayStatus" -o tsv)

    if [[ "$vm_status" != *"running"* ]]; then
        echo "Skipping VM $vm_name (status: $vm_status)"
        continue
    fi

    echo "Running disk check on $vm_name..."
    az vm run-command invoke \
        --resource-group "$resource_group" \
        --name "$vm_name" \
        --command-id RunShellScript \
        --scripts "cat /proc/uptime | awk '{print \$1/86400}'" \
        > "${OUTPUT_DIR}/${vm_name}_raw_output.json"
done