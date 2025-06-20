*** Settings ***
Documentation       This SLI measures the health of Azure VM disk utilization.
Metadata            Author    augment-code
Metadata            Display Name    Azure VM Disk Health
Metadata            Supports    Azure,Virtual Machine,Disk

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             OperatingSystem
Library             DateTime
Library             Collections
Library             String

Suite Setup         Suite Initialization


*** Tasks ***
Generate Health Score for VM `${VM_NAME}` In Resource Group `${AZ_RESOURCE_GROUP}`
    [Documentation]    Generates a health score based on disk utilization.
    ${process}=    RW.CLI.Run Bash File
    ...    bash_file=vm_disk_health_score.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    
    ${health_score}=    RW.CLI.Parse Cli Json Output
    ...    rsp=${process}
    ...    extract_path_to_var__health_score=health_score
    
    ${health_score_num}=    Convert To Number    ${health_score}
    RW.Core.Push Metric    ${health_score_num}


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