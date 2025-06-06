*** Settings ***
Documentation       Runs diagnostic checks against Azure VMs to monitor disk utilization.
Metadata            Author    augment-code
Metadata            Display Name    Azure VM Disk Health Check
Metadata            Supports    Azure    Virtual Machine    Disk    Health

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             String

Suite Setup         Suite Initialization


*** Tasks ***
Check Disk Utilization for VM `${VM_NAME}` In Resource Group `${AZ_RESOURCE_GROUP}`
    [Documentation]    Checks disk utilization of Azure VM and reports issues if usage exceeds threshold.
    [Tags]    VM    Azure    Disk    Health
    ${process}=    RW.CLI.Run Bash File
    ...    bash_file=vm_disk_utilization.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    RW.Core.Add Pre To Report    ${process.stdout}

    ${issues}=    RW.CLI.Run Cli    cmd=cat ${OUTPUT DIR}/issues.json 
    Log    ${issues.stdout}
    ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    IF    len(@{issue_list["issues"]}) > 0
        FOR    ${item}    IN    @{issue_list["issues"]}
            RW.Core.Add Issue    
            ...    title=${item["title"]}
            ...    severity=${item["severity"]}
            ...    next_steps=${item["next_step"]}
            ...    expected=VM `${VM_NAME}` in resource group `${AZ_RESOURCE_GROUP}` should have disk usage below threshold
            ...    actual=VM `${VM_NAME}` in resource group `${AZ_RESOURCE_GROUP}` has disks with usage above threshold
            ...    reproduce_hint=Run vm_disk_utilization.sh
            ...    details=${item["details"]}        
        END
    END

Get VM Details for `${VM_NAME}` In Resource Group `${AZ_RESOURCE_GROUP}`
    [Documentation]    Fetches detailed information about the VM.
    [Tags]    VM    Azure    Info
    ${vm_details}=    RW.CLI.Run Cli
    ...    cmd=az vm show --name ${VM_NAME} --resource-group ${AZ_RESOURCE_GROUP} --query "{name:name, location:location, vmSize:hardwareProfile.vmSize, osType:storageProfile.osDisk.osType, provisioningState:provisioningState}" -o json
    ...    env=${env}
    ...    timeout_seconds=60
    ...    include_in_history=false
    RW.Core.Add Pre To Report    VM Details:\n${vm_details.stdout}

List Attached Disks for VM `${VM_NAME}` In Resource Group `${AZ_RESOURCE_GROUP}`
    [Documentation]    Lists all disks attached to the VM.
    [Tags]    VM    Azure    Disk    Info
    ${disks}=    RW.CLI.Run Cli
    ...    cmd=az vm show --name ${VM_NAME} --resource-group ${AZ_RESOURCE_GROUP} --query "storageProfile.dataDisks[].{name:name, diskSizeGB:diskSizeGB, lun:lun, caching:caching}" -o json
    ...    env=${env}
    ...    timeout_seconds=60
    ...    include_in_history=false
    RW.Core.Add Pre To Report    Attached Data Disks:\n${disks.stdout}


*** Keywords ***
Suite Initialization
    ${AZ_RESOURCE_GROUP}=    RW.Core.Import User Variable    AZ_RESOURCE_GROUP
    ...    type=string
    ...    description=The resource group containing the VM(s).
    ...    pattern=\w*
    ${VM_NAME}=    RW.Core.Import User Variable    VM_NAME
    ...    type=string
    ...    description=The Azure Virtual Machine to check. Leave empty to check all VMs in the resource group.
    ...    pattern=\w*
    ...    default=""
    ${DISK_THRESHOLD}=    RW.Core.Import User Variable    DISK_THRESHOLD
    ...    type=string
    ...    description=The threshold percentage for disk usage warnings.
    ...    pattern=\d*
    ...    default=80
    ${AZURE_RESOURCE_SUBSCRIPTION_ID}=    RW.Core.Import User Variable    AZURE_SUBSCRIPTION_ID
    ...    type=string
    ...    description=The Azure Subscription ID.
    ...    pattern=\w*
    ${azure_credentials}=    RW.Core.Import Secret
    ...    azure_credentials
    ...    type=string
    ...    description=The secret containing AZURE_CLIENT_ID, AZURE_TENANT_ID, AZURE_CLIENT_SECRET, AZURE_SUBSCRIPTION_ID
    ...    pattern=\w*
    Set Suite Variable    ${VM_NAME}    ${VM_NAME}
    Set Suite Variable    ${AZ_RESOURCE_GROUP}    ${AZ_RESOURCE_GROUP}
    Set Suite Variable    ${DISK_THRESHOLD}    ${DISK_THRESHOLD}
    Set Suite Variable
    ...    ${env}
    ...    {"VM_NAME":"${VM_NAME}", "AZ_RESOURCE_GROUP":"${AZ_RESOURCE_GROUP}", "DISK_THRESHOLD": "${DISK_THRESHOLD}", "AZURE_SUBSCRIPTION_ID":"${AZURE_RESOURCE_SUBSCRIPTION_ID}"}