*** Settings ***
Documentation       Runs diagnostic checks against Azure VMs to monitor disk utilization, memory utilization, uptime, patch status and system health.
Metadata            Author    Nbarola
Metadata            Display Name    Azure VM Health Check
Metadata            Supports    Azure    Virtual Machine    Disk    Health    Uptime

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             Azure
Library             RW.platform
Library             String
Library             OperatingSystem
Library             Collections

Suite Setup         Suite Initialization


*** Tasks ***
Check Disk Utilization for VMs in Resource Group `${AZ_RESOURCE_GROUP}`
    [Documentation]    Checks disk utilization for VMs and parses each result.
    [Tags]    VM    Azure    Disk    Health
    ${disk_usage}=    RW.CLI.Run Bash File
    ...    bash_file=vm_disk_utilization.sh
    ...    env=${env}
    ...    timeout_seconds=300
    ...    include_in_history=false
    ...    extra_env=VM_INCLUDE_LIST,VM_OMIT_LIST,MAX_PARALLEL_JOBS,TIMEOUT_SECONDS

    # Check if Azure authentication failed completely
    ${auth_failed}=    Run Keyword And Return Status    Should Contain    ${disk_usage.stdout}    Azure authentication failed
    IF    ${auth_failed}
        RW.Core.Add Issue    
            ...    title=Azure Authentication Failed for Resource Group `${AZ_RESOURCE_GROUP}` (Subscription: `${AZURE_SUBSCRIPTION_NAME}`)
            ...    severity=4
            ...    next_steps=Check Azure credentials and subscription access for Resource Group `${AZ_RESOURCE_GROUP}`
            ...    expected=Azure CLI should authenticate successfully
            ...    actual=Azure authentication failed for subscription ${AZURE_RESOURCE_SUBSCRIPTION_ID}
            ...    reproduce_hint=Run: az account show --subscription ${AZURE_RESOURCE_SUBSCRIPTION_ID}
            ...    details={"error": "Azure authentication failed", "subscription": "${AZURE_RESOURCE_SUBSCRIPTION_ID}", "resource_group": "${AZ_RESOURCE_GROUP}"}
        RETURN
    END

    ${disk_usg_out}=    Evaluate    json.loads(r'''${disk_usage.stdout}''')    json
    ${vm_names}=    Get Dictionary Keys    ${disk_usg_out}
    ${summary}=    Set Variable    Disk Utilization Results:\n
    FOR    ${vm_name}    IN    @{vm_names}
        ${vm_data}=    Get From Dictionary    ${disk_usg_out}    ${vm_name}
        ${stdout}=    Get From Dictionary    ${vm_data}    stdout
        ${stderr}=    Get From Dictionary    ${vm_data}    stderr
        ${status}=    Get From Dictionary    ${vm_data}    status
        ${code}=    Get From Dictionary    ${vm_data}    code

        # Handle connectivity and authentication issues with severity 4
        IF    "${code}" in ["ConnectionError", "CommandTimeout", "InvalidResponse", "VMNotRunning"]
            ${severity}=    Set Variable If    "${code}" == "VMNotRunning"    3    4
            ${issue_title}=    Set Variable If    "${code}" == "VMNotRunning"    
            ...    VM `${vm_name}` Not Running in Resource Group `${AZ_RESOURCE_GROUP}` (Subscription: `${AZURE_SUBSCRIPTION_NAME}`)
            ...    Connection Issue with VM `${vm_name}` in Resource Group `${AZ_RESOURCE_GROUP}` (Subscription: `${AZURE_SUBSCRIPTION_NAME}`)
            ${next_steps}=    Set Variable If    "${code}" == "VMNotRunning"
            ...    Start VM `${vm_name}` in resource group `${AZ_RESOURCE_GROUP}` or investigate why it's not running
            ...    Check network connectivity and Azure credentials for VM `${vm_name}` in resource group `${AZ_RESOURCE_GROUP}` (subscription: `${AZURE_SUBSCRIPTION_NAME}`)
            
            RW.Core.Add Issue    
                ...    title=${issue_title}
                ...    severity=${severity}
                ...    next_steps=${next_steps}
                ...    expected=VM should be accessible and running
                ...    actual=${stderr}
                ...    reproduce_hint=Run vm_disk_utilization.sh or check VM status
                ...    details=${vm_data}
            ${summary}=    Catenate    SEPARATOR=\n    ${summary}    VM: ${vm_name} (${status}) - ${stderr}
        ELSE IF    "${stderr}" != ""
            RW.Core.Add Issue    
                ...    title=Error detected during disk check for VM `${vm_name}` in Resource Group `${AZ_RESOURCE_GROUP}` (Subscription: `${AZURE_SUBSCRIPTION_NAME}`)
                ...    severity=1
                ...    next_steps=Investigate the error: ${stderr}
                ...    expected=No errors should occur during disk health check
                ...    actual=${stderr}
                ...    reproduce_hint=Run vm_disk_utilization.sh
                ...    details=${vm_data}
            ${summary}=    Catenate    SEPARATOR=\n    ${summary}    VM: ${vm_name} (${status}) - Error: ${stderr}
        ELSE
            ${summary}=    Catenate    SEPARATOR=\n    ${summary}    VM: ${vm_name} (${status})\n${stdout}
            # Write stdout to temp file for next steps analysis
            ${tmpfile}=    Generate Random String    8
            ${tmpfile_path}=    Set Variable    /tmp/vm_disk_stdout.txt
            Create File    ${tmpfile_path}    ${stdout}

            ${next_steps}=    RW.CLI.Run Bash File
            ...    bash_file=next_steps_disk_utilization.sh
            ...    args=${tmpfile_path}
            ...    env=${env}
            ...    timeout_seconds=180
            ...    include_in_history=false

            ${issues_list}=     RW.CLI.Run Cli
            ...     cmd=cat disk_utilization_issues.json
            # Process issues if any were found
            ${issues}=    Evaluate    json.loads(r'''${issues_list.stdout}''')    json
            IF    len(@{issues}) > 0
                FOR    ${issue}    IN    @{issues}
                    RW.Core.Add Issue
                    ...    severity=${issue['severity']}
                    ...    expected=${issue['expected']}
                    ...    actual=${issue['actual']}
                    ...    title=${issue['title']}
                    ...    reproduce_hint=Run vm_disk_utilization.sh
                    ...    next_steps=${issue['next_steps']}
                    ...    details=${issue['details']}
                END
            END
        END
    END
    RW.Core.Add Pre To Report    ${summary}

Check Memory Utilization for VMs in Resource Group `${AZ_RESOURCE_GROUP}`
    [Documentation]    Checks memory utilization for VMs and parses each result.
    [Tags]    VM    Azure    Memory    Health
    ${memory_usage}=    RW.CLI.Run Bash File
    ...    bash_file=vm_memory_check.sh
    ...    env=${env}
    ...    timeout_seconds=300
    ...    include_in_history=false
    ...    extra_env=VM_INCLUDE_LIST,VM_OMIT_LIST,MAX_PARALLEL_JOBS,TIMEOUT_SECONDS

    # Check if Azure authentication failed completely
    ${auth_failed}=    Run Keyword And Return Status    Should Contain    ${memory_usage.stdout}    Azure authentication failed
    IF    ${auth_failed}
        RW.Core.Add Issue    
            ...    title=Azure Authentication Failed for Resource Group `${AZ_RESOURCE_GROUP}` (Subscription: `${AZURE_SUBSCRIPTION_NAME}`)
            ...    severity=4
            ...    next_steps=Check Azure credentials and subscription access for Resource Group `${AZ_RESOURCE_GROUP}`
            ...    expected=Azure CLI should authenticate successfully
            ...    actual=Azure authentication failed for subscription ${AZURE_RESOURCE_SUBSCRIPTION_ID}
            ...    reproduce_hint=Run: az account show --subscription ${AZURE_RESOURCE_SUBSCRIPTION_ID}
            ...    details={"error": "Azure authentication failed", "subscription": "${AZURE_RESOURCE_SUBSCRIPTION_ID}", "resource_group": "${AZ_RESOURCE_GROUP}"}
        RETURN
    END

    ${mem_usg_out}=    Evaluate    json.loads(r'''${memory_usage.stdout}''')    json
    ${vm_names}=    Get Dictionary Keys    ${mem_usg_out}
    ${summary}=    Set Variable    Memory Utilization Results:\n
    FOR    ${vm_name}    IN    @{vm_names}
        ${vm_data}=    Get From Dictionary    ${mem_usg_out}    ${vm_name}
        ${stdout}=    Get From Dictionary    ${vm_data}    stdout
        ${stderr}=    Get From Dictionary    ${vm_data}    stderr
        ${status}=    Get From Dictionary    ${vm_data}    status
        ${code}=    Get From Dictionary    ${vm_data}    code

        # Handle connectivity and authentication issues with severity 4
        IF    "${code}" in ["ConnectionError", "CommandTimeout", "InvalidResponse", "VMNotRunning"]
            ${severity}=    Set Variable If    "${code}" == "VMNotRunning"    3    4
            ${issue_title}=    Set Variable If    "${code}" == "VMNotRunning"    
            ...    VM `${vm_name}` Not Running in Resource Group `${AZ_RESOURCE_GROUP}` (Subscription: `${AZURE_SUBSCRIPTION_NAME}`)
            ...    Connection Issue with VM `${vm_name}` in Resource Group `${AZ_RESOURCE_GROUP}` (Subscription: `${AZURE_SUBSCRIPTION_NAME}`)
            ${next_steps}=    Set Variable If    "${code}" == "VMNotRunning"
            ...    Start VM `${vm_name}` in resource group `${AZ_RESOURCE_GROUP}` or investigate why it's not running
            ...    Check network connectivity and Azure credentials for VM `${vm_name}` in resource group `${AZ_RESOURCE_GROUP}` (subscription: `${AZURE_SUBSCRIPTION_NAME}`)
            
            RW.Core.Add Issue    
                ...    title=${issue_title}
                ...    severity=${severity}
                ...    next_steps=${next_steps}
                ...    expected=VM should be accessible and running
                ...    actual=${stderr}
                ...    reproduce_hint=Run vm_memory_check.sh or check VM status
                ...    details=${vm_data}
            ${summary}=    Catenate    SEPARATOR=\n    ${summary}    VM: ${vm_name} (${status}) - ${stderr}
        ELSE IF    "${stderr}" != ""
            RW.Core.Add Issue    
                ...    title=Error detected during memory check for VM `${vm_name}` in Resource Group `${AZ_RESOURCE_GROUP}` (Subscription: `${AZURE_SUBSCRIPTION_NAME}`)
                ...    severity=1
                ...    next_steps=Investigate the error: ${stderr}
                ...    expected=No errors should occur during memory check
                ...    actual=${stderr}
                ...    reproduce_hint=Run vm_memory_check.sh
                ...    details=${vm_data}
            ${summary}=    Catenate    SEPARATOR=\n    ${summary}    VM: ${vm_name} (${status}) - Error: ${stderr}
        ELSE
            ${summary}=    Catenate    SEPARATOR=\n    ${summary}    VM: ${vm_name} (${status})\n${stdout}
            ${tmpfile}=    Generate Random String    8
            ${tmpfile_path}=    Set Variable    /tmp/vm_mem_stdout.txt
            Create File    ${tmpfile_path}    ${stdout}

            ${next_steps}=    RW.CLI.Run Bash File
            ...    bash_file=next_steps_memory_check.sh
            ...    args=${tmpfile_path}
            ...    env=${env}
            ...    timeout_seconds=180
            ...    include_in_history=false

            ${issues_list}=     RW.CLI.Run Cli
            ...     cmd=cat memory_utilization_issues.json
            ${issues}=    Evaluate    json.loads(r'''${issues_list.stdout}''')    json
            IF    len(@{issues}) > 0
                FOR    ${issue}    IN    @{issues}
                    RW.Core.Add Issue
                    ...    severity=${issue['severity']}
                    ...    expected=${issue['expected']}
                    ...    actual=${issue['actual']}
                    ...    title=${issue['title']}
                    ...    reproduce_hint=Run vm_memory_check.sh
                    ...    next_steps=${issue['next_steps']}
                    ...    details=${issue['details']}
                END
            END
        END
    END
    RW.Core.Add Pre To Report    ${summary}

Check Uptime for VMs in Resource Group `${AZ_RESOURCE_GROUP}`
    [Documentation]    Checks uptime for VMs and parses each result.
    [Tags]    VM    Azure    Uptime    Health
    ${uptime_usage}=    RW.CLI.Run Bash File
    ...    bash_file=vm_uptime_check.sh
    ...    env=${env}
    ...    timeout_seconds=300
    ...    include_in_history=false
    ...    extra_env=VM_INCLUDE_LIST,VM_OMIT_LIST,MAX_PARALLEL_JOBS,TIMEOUT_SECONDS

    # Check if Azure authentication failed completely
    ${auth_failed}=    Run Keyword And Return Status    Should Contain    ${uptime_usage.stdout}    Azure authentication failed
    IF    ${auth_failed}
        RW.Core.Add Issue    
            ...    title=Azure Authentication Failed for Resource Group `${AZ_RESOURCE_GROUP}` (Subscription: `${AZURE_SUBSCRIPTION_NAME}`)
            ...    severity=4
            ...    next_steps=Check Azure credentials and subscription access for Resource Group `${AZ_RESOURCE_GROUP}`
            ...    expected=Azure CLI should authenticate successfully
            ...    actual=Azure authentication failed for subscription ${AZURE_RESOURCE_SUBSCRIPTION_ID}
            ...    reproduce_hint=Run: az account show --subscription ${AZURE_RESOURCE_SUBSCRIPTION_ID}
            ...    details={"error": "Azure authentication failed", "subscription": "${AZURE_RESOURCE_SUBSCRIPTION_ID}", "resource_group": "${AZ_RESOURCE_GROUP}"}
        RETURN
    END

    ${uptime_usg_out}=    Evaluate    json.loads(r'''${uptime_usage.stdout}''')    json
    ${vm_names}=    Get Dictionary Keys    ${uptime_usg_out}
    ${summary}=    Set Variable    Uptime Results:\n
    FOR    ${vm_name}    IN    @{vm_names}
        ${vm_data}=    Get From Dictionary    ${uptime_usg_out}    ${vm_name}
        ${stdout}=    Get From Dictionary    ${vm_data}    stdout
        ${stderr}=    Get From Dictionary    ${vm_data}    stderr
        ${status}=    Get From Dictionary    ${vm_data}    status
        ${code}=    Get From Dictionary    ${vm_data}    code

        # Handle connectivity and authentication issues with severity 4
        IF    "${code}" in ["ConnectionError", "CommandTimeout", "InvalidResponse", "VMNotRunning"]
            ${severity}=    Set Variable If    "${code}" == "VMNotRunning"    3    4
            ${issue_title}=    Set Variable If    "${code}" == "VMNotRunning"    
            ...    VM `${vm_name}` Not Running in Resource Group `${AZ_RESOURCE_GROUP}` (Subscription: `${AZURE_SUBSCRIPTION_NAME}`)
            ...    Connection Issue with VM `${vm_name}` in Resource Group `${AZ_RESOURCE_GROUP}` (Subscription: `${AZURE_SUBSCRIPTION_NAME}`)
            ${next_steps}=    Set Variable If    "${code}" == "VMNotRunning"
            ...    Start VM `${vm_name}` in resource group `${AZ_RESOURCE_GROUP}` or investigate why it's not running
            ...    Check network connectivity and Azure credentials for VM `${vm_name}` in resource group `${AZ_RESOURCE_GROUP}` (subscription: `${AZURE_SUBSCRIPTION_NAME}`)
            
            RW.Core.Add Issue    
                ...    title=${issue_title}
                ...    severity=${severity}
                ...    next_steps=${next_steps}
                ...    expected=VM should be accessible and running
                ...    actual=${stderr}
                ...    reproduce_hint=Run vm_uptime_check.sh or check VM status
                ...    details=${vm_data}
            ${summary}=    Catenate    SEPARATOR=\n    ${summary}    VM: ${vm_name} (${status}) - ${stderr}
        ELSE IF    "${stderr}" != ""
            RW.Core.Add Issue    
                ...    title=Error detected during uptime check for VM `${vm_name}` in Resource Group `${AZ_RESOURCE_GROUP}` (Subscription: `${AZURE_SUBSCRIPTION_NAME}`)
                ...    severity=1
                ...    next_steps=Investigate the error: ${stderr}
                ...    expected=No errors should occur during uptime check
                ...    actual=${stderr}
                ...    reproduce_hint=Run vm_uptime_check.sh
                ...    details=${vm_data}
            ${summary}=    Catenate    SEPARATOR=\n    ${summary}    VM: ${vm_name} (${status}) - Error: ${stderr}
        ELSE
            ${summary}=    Catenate    SEPARATOR=\n    ${summary}    VM: ${vm_name} (${status})\n${stdout}
            ${tmpfile}=    Generate Random String    8
            ${tmpfile_path}=    Set Variable    /tmp/vm_uptime_stdout.txt
            Create File    ${tmpfile_path}    ${stdout}

            ${next_steps}=    RW.CLI.Run Bash File
            ...    bash_file=next_steps_uptime.sh
            ...    args=${tmpfile_path}
            ...    env=${env}
            ...    timeout_seconds=180
            ...    include_in_history=false

            ${issues_list}=     RW.CLI.Run Cli
            ...     cmd=cat uptime_issues.json
            ${issues}=    Evaluate    json.loads(r'''${issues_list.stdout}''')    json
            IF    len(@{issues}) > 0
                FOR    ${issue}    IN    @{issues}
                    RW.Core.Add Issue
                    ...    severity=${issue['severity']}
                    ...    expected=${issue['expected']}
                    ...    actual=${issue['actual']}
                    ...    title=${issue['title']}
                    ...    reproduce_hint=Run vm_uptime_check.sh
                    ...    next_steps=${issue['next_steps']}
                    ...    details=${issue['details']}
                END
            END
        END
    END
    RW.Core.Add Pre To Report    ${summary}

Check Last Patch Status for VMs in Resource Group `${AZ_RESOURCE_GROUP}`
    [Documentation]    Checks last patch status for VMs and parses each result.
    [Tags]    VM    Azure    Patch    Health
    ${patch_usage}=    RW.CLI.Run Bash File
    ...    bash_file=vm_last_patch_check.sh
    ...    env=${env}
    ...    timeout_seconds=300
    ...    include_in_history=false
    ...    extra_env=VM_INCLUDE_LIST,VM_OMIT_LIST,MAX_PARALLEL_JOBS,TIMEOUT_SECONDS

    # Check if Azure authentication failed completely
    ${auth_failed}=    Run Keyword And Return Status    Should Contain    ${patch_usage.stdout}    Azure authentication failed
    IF    ${auth_failed}
        RW.Core.Add Issue    
            ...    title=Azure Authentication Failed for Resource Group `${AZ_RESOURCE_GROUP}` (Subscription: `${AZURE_SUBSCRIPTION_NAME}`)
            ...    severity=4
            ...    next_steps=Check Azure credentials and subscription access for Resource Group `${AZ_RESOURCE_GROUP}`
            ...    expected=Azure CLI should authenticate successfully
            ...    actual=Azure authentication failed for subscription ${AZURE_RESOURCE_SUBSCRIPTION_ID}
            ...    reproduce_hint=Run: az account show --subscription ${AZURE_RESOURCE_SUBSCRIPTION_ID}
            ...    details={"error": "Azure authentication failed", "subscription": "${AZURE_RESOURCE_SUBSCRIPTION_ID}", "resource_group": "${AZ_RESOURCE_GROUP}"}
        RETURN
    END

    ${patch_usg_out}=    Evaluate    json.loads(r'''${patch_usage.stdout}''')    json
    ${vm_names}=    Get Dictionary Keys    ${patch_usg_out}
    ${summary}=    Set Variable    Patch Status Results:\n
    FOR    ${vm_name}    IN    @{vm_names}
        ${vm_data}=    Get From Dictionary    ${patch_usg_out}    ${vm_name}
        ${stdout}=    Get From Dictionary    ${vm_data}    stdout
        ${stderr}=    Get From Dictionary    ${vm_data}    stderr
        ${status}=    Get From Dictionary    ${vm_data}    status
        ${code}=    Get From Dictionary    ${vm_data}    code

        # Handle connectivity and authentication issues with severity 4
        IF    "${code}" in ["ConnectionError", "CommandTimeout", "InvalidResponse", "VMNotRunning"]
            ${severity}=    Set Variable If    "${code}" == "VMNotRunning"    3    4
            ${issue_title}=    Set Variable If    "${code}" == "VMNotRunning"    
            ...    VM `${vm_name}` Not Running in Resource Group `${AZ_RESOURCE_GROUP}` (Subscription: `${AZURE_SUBSCRIPTION_NAME}`)
            ...    Connection Issue with VM `${vm_name}` in Resource Group `${AZ_RESOURCE_GROUP}` (Subscription: `${AZURE_SUBSCRIPTION_NAME}`)
            ${next_steps}=    Set Variable If    "${code}" == "VMNotRunning"
            ...    Start VM `${vm_name}` in resource group `${AZ_RESOURCE_GROUP}` or investigate why it's not running
            ...    Check network connectivity and Azure credentials for VM `${vm_name}` in resource group `${AZ_RESOURCE_GROUP}` (subscription: `${AZURE_SUBSCRIPTION_NAME}`)
            
            RW.Core.Add Issue    
                ...    title=${issue_title}
                ...    severity=${severity}
                ...    next_steps=${next_steps}
                ...    expected=VM should be accessible and running
                ...    actual=${stderr}
                ...    reproduce_hint=Run vm_last_patch_check.sh or check VM status
                ...    details=${vm_data}
            ${summary}=    Catenate    SEPARATOR=\n    ${summary}    VM: ${vm_name} (${status}) - ${stderr}
        ELSE IF    "${stderr}" != ""
            RW.Core.Add Issue    
                ...    title=Error detected during patch check for VM `${vm_name}` in Resource Group `${AZ_RESOURCE_GROUP}` (Subscription: `${AZURE_SUBSCRIPTION_NAME}`)
                ...    severity=1
                ...    next_steps=Investigate the error: ${stderr}
                ...    expected=No errors should occur during patch check
                ...    actual=${stderr}
                ...    reproduce_hint=Run vm_last_patch_check.sh
                ...    details=${vm_data}
            ${summary}=    Catenate    SEPARATOR=\n    ${summary}    VM: ${vm_name} (${status}) - Error: ${stderr}
        ELSE
            ${summary}=    Catenate    SEPARATOR=\n    ${summary}    VM: ${vm_name} (${status})\n${stdout}
            ${tmpfile}=    Generate Random String    8
            ${tmpfile_path}=    Set Variable    /tmp/vm_patch_stdout.txt
            Create File    ${tmpfile_path}    ${stdout}

            ${next_steps}=    RW.CLI.Run Bash File
            ...    bash_file=next_steps_patch_time.sh
            ...    args=${tmpfile_path}
            ...    env=${env}
            ...    timeout_seconds=180
            ...    include_in_history=false

            ${issues_list}=     RW.CLI.Run Cli
            ...     cmd=cat patch_issues.json
            ${issues}=    Evaluate    json.loads(r'''${issues_list.stdout}''')    json
            IF    len(@{issues}) > 0
                FOR    ${issue}    IN    @{issues}
                    RW.Core.Add Issue
                    ...    severity=${issue['severity']}
                    ...    expected=${issue['expected']}
                    ...    actual=${issue['actual']}
                    ...    title=${issue['title']}
                    ...    reproduce_hint=Run vm_last_patch_check.sh
                    ...    next_steps=${issue['next_steps']}
                    ...    details=${issue['details']}
                END
            END
        END
    END
    RW.Core.Add Pre To Report    ${summary}

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
    ...    default=70
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
    ${MAX_PARALLEL_JOBS}=    RW.Core.Import User Variable    MAX_PARALLEL_JOBS
    ...    type=string
    ...    description=Maximum number of parallel VM checks to run simultaneously.
    ...    pattern=\d*
    ...    default=5
    ${TIMEOUT_SECONDS}=    RW.Core.Import User Variable    TIMEOUT_SECONDS
    ...    type=string
    ...    description=Timeout in seconds for Azure VM run-command operations.
    ...    pattern=\d*
    ...    default=60
    ${AZURE_RESOURCE_SUBSCRIPTION_ID}=    RW.Core.Import User Variable    AZURE_SUBSCRIPTION_ID
    ...    type=string
    ...    description=The Azure Subscription ID.
    ...    pattern=\w*
    ${AZURE_SUBSCRIPTION_NAME}=    RW.Core.Import User Variable    AZURE_SUBSCRIPTION_NAME
    ...    type=string
    ...    description=The Azure Subscription Name.
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
    Set Suite Variable    ${MAX_PARALLEL_JOBS}    ${MAX_PARALLEL_JOBS}
    Set Suite Variable    ${TIMEOUT_SECONDS}    ${TIMEOUT_SECONDS}
    Set Suite Variable
    ...    ${env}
    ...    {"VM_NAME":"${VM_NAME}", "AZ_RESOURCE_GROUP":"${AZ_RESOURCE_GROUP}", "DISK_THRESHOLD": "${DISK_THRESHOLD}", "UPTIME_THRESHOLD": "${UPTIME_THRESHOLD}", "MEMORY_THRESHOLD": "${MEMORY_THRESHOLD}", "MAX_PARALLEL_JOBS": "${MAX_PARALLEL_JOBS}", "TIMEOUT_SECONDS": "${TIMEOUT_SECONDS}", "AZURE_SUBSCRIPTION_ID":"${AZURE_RESOURCE_SUBSCRIPTION_ID}", "AZURE_SUBSCRIPTION_NAME":"${AZURE_SUBSCRIPTION_NAME}"}
    # Set Azure subscription context
    RW.CLI.Run Cli
    ...    cmd=az account set --subscription ${AZURE_RESOURCE_SUBSCRIPTION_ID}
    ...    include_in_history=false