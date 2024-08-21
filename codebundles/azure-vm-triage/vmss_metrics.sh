#!/bin/bash

# ENV:
# AZ_USERNAME
# AZ_SECRET_VALUE
# AZ_TENANT
# AZ_SUBSCRIPTION
# AZ_RESOURCE_GROUP
# VMSCALEDSET

CPU_METRIC="Percentage CPU"
MEM_METRIC="Available Memory Bytes"

ALLOWED_CPU=80
ALLOWED_MEM=$((256 * 1048576)) # mb
METRIC_TOP=100

# Log in to Azure CLI
az login --service-principal --username $AZ_USERNAME --password $AZ_SECRET_VALUE --tenant $AZ_TENANT > /dev/null
# Set the subscription
az account set --subscription $AZ_SUBSCRIPTION

ok=0
next_steps=()
cpu_data=$(az monitor metrics list --resource $VMSCALEDSET --resource-group $AZ_RESOURCE_GROUP --resource-type Microsoft.Compute/virtualMachineScaleSets --metric "$CPU_METRIC" --interval 5m --aggregation maximum --top $METRIC_TOP)
mem_data=$(az monitor metrics list --resource $VMSCALEDSET --resource-group $AZ_RESOURCE_GROUP --resource-type Microsoft.Compute/virtualMachineScaleSets --metric "$MEM_METRIC" --interval 5m --aggregation minimum --top $METRIC_TOP)

# Check if "maximum" is available in the JSON
if echo "$mem_data" | jq -e '.value[].timeseries[].data[].maximum' >/dev/null; then
    for metric in $(echo "$cpu_data" | jq -r '.value[].timeseries[].data[].maximum | numbers'); do
        if (( $(echo "$metric > $ALLOWED_CPU" | bc -l) )); then
            echo "Found CPU usage above the allowed threshold: $ALLOWED_CPU for Azure VM Scaled Set $VMSCALEDSET in $AZ_RESOURCE_GROUP"
            next_steps+=("Increase Azure VM Scaled Set $VMSCALEDSET CPU\n")
            ok=1
            break
        fi
    done
else
    echo "No 'maximum' field available in the JSON data."
fi

# Check if "minimum" is available in the JSON
if echo "$mem_data" | jq -e '.value[].timeseries[].data[].minimum' >/dev/null; then
    # Loop through the "minimum" values
    for metric in $(echo "$mem_data" | jq -r '.value[].timeseries[].data[].minimum'); do
        if (( $(echo "$metric < $ALLOWED_MEM" | bc -l) )); then
            echo "Current memory available $metric is below the safety threshold: $ALLOWED_MEM for Azure VM Scaled Set $VMSCALEDSET in $AZ_RESOURCE_GROUP"
            next_steps+=("Increase Azure VM Scaled Set $VMSCALEDSET memory\n")
            ok=1
            break
        fi
    done
else
    echo "No 'minimum' field available in the JSON data."
fi

if [ $ok -eq 1 ]; then
    echo "Error: The Azure VM Scaled Set $VMSCALEDSET in $AZ_RESOURCE_GROUP failed one or more key metric checks"
    echo ""
    echo "Next Steps:"
    echo -e "${next_steps[@]}"
    exit 1
else
    echo "Azure VM Scaled Set $VMSCALEDSET in $AZ_RESOURCE_GROUP passed all key metric checks"
    exit 0
fi