*** Settings ***
Documentation       Runs diagnostic checks against Azure VMs to monitor disk utilization and system health.
Metadata            Author    augment-code
Metadata            Display Name    Azure VM Health Check
Metadata            Supports    Azure    Virtual Machine    Disk    Health    Uptime

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             Azure
Library             RW.platform
Library             String

Suite Setup         Suite Initialization


*** Tasks ***
Check Disk Utilization for VMs in Resource Group `${AZ_RESOURCE_GROUP}`
    [Documentation]    Checks disk utilization for VMs and parses each result.
    [Tags]    VM    Azure    Disk    Health
    ${disk_usage}=    RW.CLI.Run Bash File
    ...    bash_file=vm_disk_utilization.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    RW.Core.Add Pre To Report    ${disk_usage.stdout}

    ${disk_usg_out}=    Evaluate    json.loads(r'''${disk_usage.stdout}''')    json
    IF    len(@{disk_usg_out}) > 0
        FOR    ${disk_usg}    IN    @{disk_usg_out}
            ${vm_name}=    Set Variable    ${disk_usg_out['vm_name']}
            ${command_output}=    Set Variable    ${disk_usg_out['command_output']}

            # Write command_output to a temp file
            ${tmpfile}=    Generate Random String    8
            ${tmpfile_path}=    Set Variable    /tmp/vm_disk_${tmpfile}.txt
            Create File    ${tmpfile_path}    ${command_output}

            # Parse the output using our invoke cmd parser
            ${parsed_out}=  Azure.Run Invoke Cmd Parser
            ...     input_file=${tmpfile_path}
            ...     timeout_seconds=60
    
            # check if parsed_out.stderr is empty, if its empty then run next steps script and then generate issue else generate issue with stderr value
            IF    ${parsed_out.stderr} != ""
                RW.Core.Add Issue    
                        ...    title=Error detected during disk check
                        ...    severity=1
                        ...    next_steps=Investigate the error: ${parsed_out.stderr}
                        ...    expected=No errors should occur during disk health check
                        ...    actual=${parsed_out.stderr}
                        ...    reproduce_hint=Run vm_disk_utilization.sh
                        ...    details=${parsed_out}
        ELSE
                ${issues_list}=    RW.CLI.Run Bash File
                ...    bash_file=next_steps_disk_utilization.sh
                ...    env=${env}
                ...    timeout_seconds=180
                ...    include_in_history=false

                # Process issues if any were found
                ${issues}=    Evaluate    json.loads(r'''${issues_list.stdout}''')    json
                IF    len(@{issues}) > 0
                    FOR    ${issue}    IN    @{issues}
                        RW.Core.Add Issue
                        ...    severity=${issue['severity']}
                        ...    expected=${issue['expected']}
                        ...    actual=${issue['actual']}
                        ...    title=${issue['title']}
                        ...    reproduce_hint=${results.cmd}
                        ...    next_steps=${issue['next_steps']}
                        ...    details=${issue['details']}
                    END
                END
            END
        END
    END

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
    ${UPTIME_THRESHOLD}=    RW.Core.Import User Variable    UPTIME_THRESHOLD
    ...    type=string
    ...    description=The threshold in days for system uptime warnings.
    ...    pattern=\d*
    ...    default=30
    ${MEMORY_THRESHOLD}=    RW.Core.Import User Variable    MEMORY_THRESHOLD
    ...    type=string
    ...    description=The threshold percentage for memory usage warnings.
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
    Set Suite Variable    ${UPTIME_THRESHOLD}    ${UPTIME_THRESHOLD}
    Set Suite Variable    ${MEMORY_THRESHOLD}    ${MEMORY_THRESHOLD}
    Set Suite Variable
    ...    ${env}
    ...    {"VM_NAME":"${VM_NAME}", "AZ_RESOURCE_GROUP":"${AZ_RESOURCE_GROUP}", "DISK_THRESHOLD": "${DISK_THRESHOLD}", "UPTIME_THRESHOLD": "${UPTIME_THRESHOLD}", "MEMORY_THRESHOLD": "${MEMORY_THRESHOLD}", "AZURE_SUBSCRIPTION_ID":"${AZURE_RESOURCE_SUBSCRIPTION_ID}"}
