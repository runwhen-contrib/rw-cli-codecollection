#!/bin/bash
# vm_last_patch_check.sh

SUBSCRIPTION_ID=${AZURE_SUBSCRIPTION_ID}
RESOURCE_GROUP=${AZ_RESOURCE_GROUP}
VM_INCLUDE_LIST=${VM_INCLUDE_LIST:-""}
VM_OMIT_LIST=${VM_OMIT_LIST:-""}
OUTPUT_FILE="vm-last-patch.json"
MAX_PARALLEL_JOBS=${MAX_PARALLEL_JOBS:-5}
TIMEOUT_SECONDS=${TIMEOUT_SECONDS:-60}

# Test Azure CLI authentication early
if ! az account show --subscription "${SUBSCRIPTION_ID}" >/dev/null 2>&1; then
    echo "Failed to authenticate with Azure CLI for subscription ${SUBSCRIPTION_ID}" >&2
    echo '{"error": "Azure authentication failed"}' 
    exit 1
fi

az account set --subscription "${SUBSCRIPTION_ID}"

vms=$(az vm list --resource-group "${RESOURCE_GROUP}" --query "[].{name:name, resourceGroup:resourceGroup}" -o json 2>/dev/null)

if [ $? -ne 0 ] || [ "$(echo $vms | jq length)" -eq "0" ]; then
    echo "No VMs found in resource group ${RESOURCE_GROUP} or failed to list VMs" >&2
    echo "{}"
    exit 0
fi

shopt -s extglob
IFS=',' read -ra INCLUDE_PATTERNS <<< "$VM_INCLUDE_LIST"
IFS=',' read -ra OMIT_PATTERNS <<< "$VM_OMIT_LIST"

filter_vm() {
    local vm_name="$1"
    if [ -n "$VM_INCLUDE_LIST" ]; then
        local match=0
        for pat in "${INCLUDE_PATTERNS[@]}"; do
            if [[ "$vm_name" == $pat ]]; then
                match=1
                break
            fi
        done
        [ $match -eq 0 ] && return 1
    fi
    if [ -n "$VM_OMIT_LIST" ]; then
        for pat in "${OMIT_PATTERNS[@]}"; do
            if [[ "$vm_name" == $pat ]]; then
                return 1
            fi
        done
    fi
    return 0
}

# Function to check a single VM
check_vm_patch() {
    local vm_name="$1"
    local resource_group="$2"
    local temp_file="$3"

    # Check VM power state first with timeout
    vm_status=$(timeout $TIMEOUT_SECONDS az vm get-instance-view -g "$resource_group" -n "$vm_name" \
        --query "instanceView.statuses[?starts_with(code,'PowerState/')].displayStatus" -o tsv 2>/dev/null)

    if [ $? -ne 0 ] || [[ "$vm_status" != *"running"* ]]; then
        if [ $? -ne 0 ]; then
            # Connection/auth issue
            jq -n --arg name "$vm_name" --arg stderr "Failed to get VM status - connection or authentication issue" --arg status "Connection Failed" --arg code "ConnectionError" \
                '{($name): {stdout: "", stderr: $stderr, status: $status, code: $code}}' > "$temp_file"
        else
            echo "Skipping VM $vm_name (status: $vm_status)" >&2
            jq -n --arg name "$vm_name" --arg stderr "VM not running (status: $vm_status)" --arg status "$vm_status" --arg code "VMNotRunning" \
                '{($name): {stdout: "", stderr: $stderr, status: $status, code: $code}}' > "$temp_file"
        fi
        return
    fi

    echo "Checking last patch status on $vm_name..." >&2
    patch_output=$(timeout $TIMEOUT_SECONDS az vm run-command invoke \
        --resource-group "$resource_group" \
        --name "$vm_name" \
        --command-id RunShellScript \
        --scripts "
        if command -v apt-get &>/dev/null; then
            # Ubuntu/Debian system
            echo 'Package Manager: APT (Ubuntu/Debian)'
            apt-get update -qq 2>/dev/null
            upgradable=\$(apt list --upgradable 2>/dev/null | grep -v 'Listing...' | wc -l)
            if [ \$upgradable -gt 0 ]; then
                echo \"Pending Updates: \$upgradable packages available for upgrade\"
                echo \"Available Updates:\"
                apt list --upgradable 2>/dev/null | grep -v 'Listing...' | head -10
                if [ \$upgradable -gt 10 ]; then
                    echo \"... and \$((upgradable - 10)) more packages\"
                fi
            else
                echo 'Pending Updates: System is up to date'
            fi
        elif command -v yum &>/dev/null; then
            # RHEL/CentOS system
            echo 'Package Manager: YUM (RHEL/CentOS)'
            upgradable=\$(yum check-update -q 2>/dev/null | grep -v '^$' | wc -l)
            if [ \$upgradable -gt 0 ]; then
                echo \"Pending Updates: \$upgradable packages available for upgrade\"
                echo \"Available Updates:\"
                yum check-update -q 2>/dev/null | head -10
                if [ \$upgradable -gt 10 ]; then
                    echo \"... and \$((upgradable - 10)) more packages\"
                fi
            else
                echo 'Pending Updates: System is up to date'
            fi
        elif command -v dnf &>/dev/null; then
            # Fedora system
            echo 'Package Manager: DNF (Fedora)'
            upgradable=\$(dnf check-update -q 2>/dev/null | grep -v '^$' | wc -l)
            if [ \$upgradable -gt 0 ]; then
                echo \"Pending Updates: \$upgradable packages available for upgrade\"
                echo \"Available Updates:\"
                dnf check-update -q 2>/dev/null | head -10
                if [ \$upgradable -gt 10 ]; then
                    echo \"... and \$((upgradable - 10)) more packages\"
                fi
            else
                echo 'Pending Updates: System is up to date'
            fi
        else
            echo 'Package Manager: Unknown/Unsupported OS'
            echo 'Pending Updates: Unable to determine patch status'
        fi
        " 2>/dev/null)

    if [ $? -ne 0 ]; then
        jq -n --arg name "$vm_name" --arg stderr "Failed to execute patch check command - timeout or connection issue" --arg status "Command Failed" --arg code "CommandTimeout" \
            '{($name): {stdout: "", stderr: $stderr, status: $status, code: $code}}' > "$temp_file"
        return
    fi

    # Extract the message from the Azure response
    message=$(echo "$patch_output" | jq -r '.value[0].message' 2>/dev/null)
    
    if [ "$message" = "null" ] || [ -z "$message" ]; then
        jq -n --arg name "$vm_name" --arg stderr "Invalid response from Azure run-command" --arg status "Invalid Response" --arg code "InvalidResponse" \
            '{($name): {stdout: "", stderr: $stderr, status: $status, code: $code}}' > "$temp_file"
        return
    fi
    
    # Extract stdout and stderr from the message
    stdout=$(echo "$message" | awk '/\[stdout\]/{flag=1;next}/\[stderr\]/{flag=0}flag' | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')
    stderr=$(echo "$message" | awk '/\[stderr\]/{flag=1}flag' | sed '1d' | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')
    
    # Get status and code from Azure response
    status=$(echo "$patch_output" | jq -r '.value[0].displayStatus' 2>/dev/null)
    code=$(echo "$patch_output" | jq -r '.value[0].code' 2>/dev/null)

    jq -n --arg name "$vm_name" --arg stdout "$stdout" --arg stderr "$stderr" --arg status "$status" --arg code "$code" \
        '{($name): {stdout: $stdout, stderr: $stderr, status: $status, code: $code}}' > "$temp_file"
}

# Create temp directory for parallel processing
temp_dir=$(mktemp -d)
trap "rm -rf $temp_dir" EXIT

results="{}"
job_count=0
declare -a pids=()
declare -a temp_files=()

while read -r vm; do
    vm_name=$(echo $vm | jq -r '.name')
    resource_group=$(echo $vm | jq -r '.resourceGroup')

    filter_vm "$vm_name" || continue

    # Create temp file for this VM's result
    temp_file="$temp_dir/vm_${vm_name}.json"
    temp_files+=("$temp_file")

    # Start background job
    check_vm_patch "$vm_name" "$resource_group" "$temp_file" &
    pids+=($!)
    ((job_count++))

    # Limit parallel jobs
    if [ $job_count -ge $MAX_PARALLEL_JOBS ]; then
        # Wait for one job to complete
        wait ${pids[0]}
        pids=("${pids[@]:1}")  # Remove first PID
        ((job_count--))
    fi
done < <(echo "$vms" | jq -c '.[]')

# Wait for all remaining jobs
for pid in "${pids[@]}"; do
    wait $pid
done

# Combine all results
for temp_file in "${temp_files[@]}"; do
    if [ -f "$temp_file" ]; then
        vm_result=$(cat "$temp_file")
        results=$(jq -s '.[0] * .[1]' <(echo "$results") <(echo "$vm_result"))
    fi
done

echo "$results"