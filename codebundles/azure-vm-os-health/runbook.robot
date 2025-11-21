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
Library             DateTime

Suite Setup         Suite Initialization


*** Tasks ***
Check Disk Utilization for VMs in Resource Group `${AZ_RESOURCE_GROUP}`
    [Documentation]    Checks disk utilization for VMs and parses each result.
    [Tags]    access:read-only    VM    Azure    Disk    Health
    ${disk_usage}=    RW.CLI.Run Bash File
    ...    bash_file=vm_disk_utilization.sh
    ...    env=${env}
    ...    timeout_seconds=300
    ...    include_in_history=false
    ...    extra_env=VM_INCLUDE_LIST,VM_OMIT_LIST,MAX_PARALLEL_JOBS,TIMEOUT_SECONDS
    ${timestamp}=    Datetime.Get Current Date

    # Check if Azure authentication failed completely
    ${auth_failed}=    Run Keyword And Return Status    Should Contain    ${disk_usage.stdout}    Azure authentication failed
    IF    ${auth_failed}
        RW.Core.Add Issue    
            ...    title=Azure Authentication Failed for Resource Group `${AZ_RESOURCE_GROUP}` (Subscription: `${AZURE_SUBSCRIPTION_NAME}`)
            ...    severity=4
            ...    next_steps=Check Azure credentials for Resource Group `${AZ_RESOURCE_GROUP}`
            ...    expected=Azure CLI should authenticate successfully
            ...    actual=Azure authentication failed for subscription ${AZURE_RESOURCE_SUBSCRIPTION_ID}
            ...    reproduce_hint=Run: az account show --subscription ${AZURE_RESOURCE_SUBSCRIPTION_ID}
            ...    details={"error": "Azure authentication failed", "subscription": "${AZURE_RESOURCE_SUBSCRIPTION_ID}", "resource_group": "${AZ_RESOURCE_GROUP}"}
            ...    observed_at=${timestamp}
    END

    ${disk_usg_out}=    Evaluate    json.loads(r'''${disk_usage.stdout}''')    json
    ${vm_names}=    Get Dictionary Keys    ${disk_usg_out}
    ${summary}=    Set Variable    Disk Utilization Results:\n

    # Initialize detailed report at the beginning
    ${detailed_report}=    Set Variable    ===== DISK UTILIZATION CHECK DETAILED REPORT =====\n
    ${detailed_report}=    Catenate    SEPARATOR=\n    ${detailed_report}    Resource Group: ${AZ_RESOURCE_GROUP}
    ${detailed_report}=    Catenate    SEPARATOR=\n    ${detailed_report}    Subscription: ${AZURE_SUBSCRIPTION_NAME} (${AZURE_RESOURCE_SUBSCRIPTION_ID})
    ${current_time}=    Get Time
    ${detailed_report}=    Catenate    SEPARATOR=\n    ${detailed_report}    Check Timestamp: ${current_time}
    ${vm_count}=    Get Length    ${vm_names}
    ${detailed_report}=    Catenate    SEPARATOR=\n    ${detailed_report}    Total VMs Scanned: ${vm_count}
    ${detailed_report}=    Catenate    SEPARATOR=\n    ${detailed_report}    Disk Usage Threshold: ${DISK_THRESHOLD}%
    ${detailed_report}=    Catenate    SEPARATOR=\n    ${detailed_report}    Parallel Jobs: ${MAX_PARALLEL_JOBS}
    ${detailed_report}=    Catenate    SEPARATOR=\n    ${detailed_report}    Timeout: ${TIMEOUT_SECONDS} seconds
    ${vm_include_display}=    Set Variable If    "${VM_INCLUDE_LIST}" == ""    All VMs    ${VM_INCLUDE_LIST}
    ${vm_omit_display}=    Set Variable If    "${VM_OMIT_LIST}" == ""    None    ${VM_OMIT_LIST}
    ${detailed_report}=    Catenate    SEPARATOR=\n    ${detailed_report}    VM Include List: ${vm_include_display}
    ${detailed_report}=    Catenate    SEPARATOR=\n    ${detailed_report}    VM Omit List: ${vm_omit_display}
    ${detailed_report}=    Catenate    SEPARATOR=\n    ${detailed_report}    \n===== VMs IN RESOURCE GROUP =====\n

    # List all VMs and their status
    FOR    ${vm_name}    IN    @{vm_names}
        ${vm_data}=    Get From Dictionary    ${disk_usg_out}    ${vm_name}
        ${status}=    Get From Dictionary    ${vm_data}    status
        ${code}=    Get From Dictionary    ${vm_data}    code
        
        IF    "${code}" in ["WindowsVM", "NotIncluded", "Omitted"]
            ${detailed_report}=    Catenate    SEPARATOR=\n    ${detailed_report}    ⏭️ ${vm_name} - SKIPPED (${code})
        ELSE IF    "${code}" in ["ConnectionError", "CommandTimeout", "InvalidResponse", "VMNotRunning"]
            ${detailed_report}=    Catenate    SEPARATOR=\n    ${detailed_report}    ❌ ${vm_name} - FAILED (${code})
        ELSE
            ${detailed_report}=    Catenate    SEPARATOR=\n    ${detailed_report}    ✅ ${vm_name} - PROCESSED (${status})
        END
    END

    ${detailed_report}=    Catenate    SEPARATOR=\n    ${detailed_report}    \n===== INDIVIDUAL VM RESULTS =====\n

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
            ...    Virtual Machine `${vm_name}` (RG: `${AZ_RESOURCE_GROUP}`) is not running (Subscription: `${AZURE_SUBSCRIPTION_NAME}`)
            ...    Virtual Machine `${vm_name}` (RG: `${AZ_RESOURCE_GROUP}`) has connection issues (Subscription: `${AZURE_SUBSCRIPTION_NAME}`)
            ${next_steps}=    Set Variable If    "${code}" == "VMNotRunning"
            ...    Start VM `${vm_name}` in resource group `${AZ_RESOURCE_GROUP}`
            ...    Check Azure connectivity for VM `${vm_name}` in resource group `${AZ_RESOURCE_GROUP}`
            
            RW.Core.Add Issue    
                ...    title=${issue_title}
                ...    severity=${severity}
                ...    next_steps=${next_steps}
                ...    expected=VM should be accessible and running
                ...    actual=${stderr}
                ...    reproduce_hint=Run vm_disk_utilization.sh or check VM status
                ...    details=${vm_data}
                ...    observed_at=${timestamp}
            ${summary}=    Catenate    SEPARATOR=\n    ${summary}    VM: ${vm_name} (${status}) - ${stderr}
            
            ${detailed_report}=    Catenate    SEPARATOR=\n    ${detailed_report}    \n--- VM: ${vm_name} ---
            ${detailed_report}=    Catenate    SEPARATOR=\n    ${detailed_report}    Status: ${status}
            ${detailed_report}=    Catenate    SEPARATOR=\n    ${detailed_report}    Code: ${code}
            ${detailed_report}=    Catenate    SEPARATOR=\n    ${detailed_report}    Result: ❌ FAILED - ${stderr}
            ${detailed_report}=    Catenate    SEPARATOR=\n    ${detailed_report}    Issue: VM is not accessible or not running
            ${detailed_report}=    Catenate    SEPARATOR=\n    ${detailed_report}    Action Required: Check VM status and connectivity
        ELSE IF    "${code}" in ["WindowsVM", "NotIncluded", "Omitted"]
            ${issue_title}=    Set Variable If    "${code}" == "WindowsVM"    
            ...    Virtual Machine `${vm_name}` (RG: `${AZ_RESOURCE_GROUP}`) is a Windows VM and was skipped (Subscription: `${AZURE_SUBSCRIPTION_NAME}`)
            ...    Virtual Machine `${vm_name}` (RG: `${AZ_RESOURCE_GROUP}`) was filtered out by VM filtering rules (Subscription: `${AZURE_SUBSCRIPTION_NAME}`)
            ${next_steps}=    Set Variable If    "${code}" == "WindowsVM"
            ...    No action required - Windows VMs are not supported by Linux health checks
            ...    Review VM_INCLUDE_LIST and VM_OMIT_LIST configuration if this VM should be included
            
            RW.Core.Add Issue    
                ...    title=${issue_title}
                ...    severity=4
                ...    next_steps=${next_steps}
                ...    expected=VM filtering working as configured
                ...    actual=${stderr}
                ...    reproduce_hint=Run vm_disk_utilization.sh or check VM filtering configuration
                ...    details=${vm_data}
                ...    observed_at=${timestamp}

            ${detailed_report}=    Catenate    SEPARATOR=\n    ${detailed_report}    \n--- VM: ${vm_name} ---
            ${detailed_report}=    Catenate    SEPARATOR=\n    ${detailed_report}    Status: ${status}
            ${detailed_report}=    Catenate    SEPARATOR=\n    ${detailed_report}    Code: ${code}
            ${detailed_report}=    Catenate    SEPARATOR=\n    ${detailed_report}    Result: ⏭️ SKIPPED - ${stderr}
            ${detailed_report}=    Catenate    SEPARATOR=\n    ${detailed_report}    Reason: VM was filtered out based on criteria
            ${detailed_report}=    Catenate    SEPARATOR=\n    ${detailed_report}    Action Required: None - this is expected behavior
        ELSE IF    "${stderr}" != ""
            RW.Core.Add Issue    
                ...    title=Virtual Machine `${vm_name}` (RG: `${AZ_RESOURCE_GROUP}`) has disk check errors (Subscription: `${AZURE_SUBSCRIPTION_NAME}`)
                ...    severity=1
                ...    next_steps=Investigate the error: ${stderr}
                ...    expected=No errors should occur during disk health check
                ...    actual=${stderr}
                ...    reproduce_hint=Run vm_disk_utilization.sh
                ...    details=${vm_data}
                ...    observed_at=${timestamp}
            ${summary}=    Catenate    SEPARATOR=\n    ${summary}    VM: ${vm_name} (${status}) - Error: ${stderr}
            
            ${detailed_report}=    Catenate    SEPARATOR=\n    ${detailed_report}    \n--- VM: ${vm_name} ---
            ${detailed_report}=    Catenate    SEPARATOR=\n    ${detailed_report}    Status: ${status}
            ${detailed_report}=    Catenate    SEPARATOR=\n    ${detailed_report}    Code: ${code}
            ${detailed_report}=    Catenate    SEPARATOR=\n    ${detailed_report}    Result: ⚠️ WARNING - ${stderr}
            ${detailed_report}=    Catenate    SEPARATOR=\n    ${detailed_report}    Issue: Disk check completed with errors
            ${detailed_report}=    Catenate    SEPARATOR=\n    ${detailed_report}    Action Required: Investigate the reported error
        ELSE
            ${summary}=    Catenate    SEPARATOR=\n    ${summary}    VM: ${vm_name} (${status})\n${stdout}
            # Write stdout to temp file for next steps analysis
            ${tmpfile}=    Generate Random String    8
            ${tmpfile_path}=    Set Variable    vm_disk_stdout_${tmpfile}.txt
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
                    ...    observed_at=${timestamp}
                END
            END
            
            ${detailed_report}=    Catenate    SEPARATOR=\n    ${detailed_report}    \n--- VM: ${vm_name} ---
            ${detailed_report}=    Catenate    SEPARATOR=\n    ${detailed_report}    Status: ${status}
            ${detailed_report}=    Catenate    SEPARATOR=\n    ${detailed_report}    Code: ${code}
            ${detailed_report}=    Catenate    SEPARATOR=\n    ${detailed_report}    Result: ✅ SUCCESS
            ${detailed_report}=    Catenate    SEPARATOR=\n    ${detailed_report}    Disk Information:
            ${detailed_report}=    Catenate    SEPARATOR=\n    ${detailed_report}    ${stdout}
            ${detailed_report}=    Catenate    SEPARATOR=\n    ${detailed_report}    Analysis: Disk utilization check completed successfully
        END
    END
    RW.Core.Add Pre To Report    ${summary}

    ${detailed_report}=    Catenate    SEPARATOR=\n    ${detailed_report}    \n===== SUMMARY =====
    ${detailed_report}=    Catenate    SEPARATOR=\n    ${detailed_report}    This check examined disk utilization across all Linux VMs in the resource group.
    ${detailed_report}=    Catenate    SEPARATOR=\n    ${detailed_report}    Windows VMs were automatically filtered out as they are not supported by this check.
    ${detailed_report}=    Catenate    SEPARATOR=\n    ${detailed_report}    The check looks for disk usage above ${DISK_THRESHOLD}% which may indicate storage issues.
    ${detailed_report}=    Catenate    SEPARATOR=\n    ${detailed_report}    Any VMs with connection issues or errors are reported for further investigation.
    ${detailed_report}=    Catenate    SEPARATOR=\n    ${detailed_report}    ============================================\n

    RW.Core.Add Pre To Report    ${detailed_report}

Check Memory Utilization for VMs in Resource Group `${AZ_RESOURCE_GROUP}`
    [Documentation]    Checks memory utilization for VMs and parses each result.
    [Tags]    access:read-only    VM    Azure    Memory    Health
    ${memory_usage}=    RW.CLI.Run Bash File
    ...    bash_file=vm_memory_check.sh
    ...    env=${env}
    ...    timeout_seconds=300
    ...    include_in_history=false
    ...    extra_env=VM_INCLUDE_LIST,VM_OMIT_LIST,MAX_PARALLEL_JOBS,TIMEOUT_SECONDS
    ${timestamp}=    Datetime.Get Current Date
    
    # Check if Azure authentication failed completely
    ${auth_failed}=    Run Keyword And Return Status    Should Contain    ${memory_usage.stdout}    Azure authentication failed
    IF    ${auth_failed}
        RW.Core.Add Issue    
            ...    title=Azure Authentication Failed for Resource Group `${AZ_RESOURCE_GROUP}` (Subscription: `${AZURE_SUBSCRIPTION_NAME}`)
            ...    severity=4
            ...    next_steps=Check Azure credentials for Resource Group `${AZ_RESOURCE_GROUP}`
            ...    expected=Azure CLI should authenticate successfully
            ...    actual=Azure authentication failed for subscription ${AZURE_RESOURCE_SUBSCRIPTION_ID}
            ...    reproduce_hint=Run: az account show --subscription ${AZURE_RESOURCE_SUBSCRIPTION_ID}
            ...    details={"error": "Azure authentication failed", "subscription": "${AZURE_RESOURCE_SUBSCRIPTION_ID}", "resource_group": "${AZ_RESOURCE_GROUP}"}
            ...    observed_at=${timestamp}
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
            ...    Virtual Machine `${vm_name}` (RG: `${AZ_RESOURCE_GROUP}`) is not running (Subscription: `${AZURE_SUBSCRIPTION_NAME}`)
            ...    Virtual Machine `${vm_name}` (RG: `${AZ_RESOURCE_GROUP}`) has connection issues (Subscription: `${AZURE_SUBSCRIPTION_NAME}`)
            ${next_steps}=    Set Variable If    "${code}" == "VMNotRunning"
            ...    Start VM `${vm_name}` in resource group `${AZ_RESOURCE_GROUP}`
            ...    Check Azure connectivity for VM `${vm_name}` in resource group `${AZ_RESOURCE_GROUP}`
            
            RW.Core.Add Issue    
                ...    title=${issue_title}
                ...    severity=${severity}
                ...    next_steps=${next_steps}
                ...    expected=VM should be accessible and running
                ...    actual=${stderr}
                ...    reproduce_hint=Run vm_memory_check.sh or check VM status
                ...    details=${vm_data}
                ...    observed_at=${timestamp}
            ${summary}=    Catenate    SEPARATOR=\n    ${summary}    VM: ${vm_name} (${status}) - ${stderr}
        ELSE IF    "${code}" in ["WindowsVM", "NotIncluded", "Omitted"]
            ${issue_title}=    Set Variable If    "${code}" == "WindowsVM"    
            ...    Virtual Machine `${vm_name}` (RG: `${AZ_RESOURCE_GROUP}`) is a Windows VM and was skipped (Subscription: `${AZURE_SUBSCRIPTION_NAME}`)
            ...    Virtual Machine `${vm_name}` (RG: `${AZ_RESOURCE_GROUP}`) was filtered out by VM filtering rules (Subscription: `${AZURE_SUBSCRIPTION_NAME}`)
            ${next_steps}=    Set Variable If    "${code}" == "WindowsVM"
            ...    No action required - Windows VMs are not supported by Linux health checks
            ...    Review VM_INCLUDE_LIST and VM_OMIT_LIST configuration if this VM should be included
            
            RW.Core.Add Issue    
                ...    title=${issue_title}
                ...    severity=4
                ...    next_steps=${next_steps}
                ...    expected=VM filtering working as configured
                ...    actual=${stderr}
                ...    reproduce_hint=Run vm_memory_check.sh or check VM filtering configuration
                ...    details=${vm_data}
                ...    observed_at=${timestamp}
            ${summary}=    Catenate    SEPARATOR=\n    ${summary}    VM: ${vm_name} (${status}) - ${stderr}
        ELSE IF    "${stderr}" != ""
            RW.Core.Add Issue    
                ...    title=Virtual Machine `${vm_name}` (RG: `${AZ_RESOURCE_GROUP}`) has memory check errors (Subscription: `${AZURE_SUBSCRIPTION_NAME}`)
                ...    severity=1
                ...    next_steps=Investigate the error: ${stderr}
                ...    expected=No errors should occur during memory check
                ...    actual=${stderr}
                ...    reproduce_hint=Run vm_memory_check.sh
                ...    details=${vm_data}
                ...    observed_at=${timestamp}
            ${summary}=    Catenate    SEPARATOR=\n    ${summary}    VM: ${vm_name} (${status}) - Error: ${stderr}
        ELSE
            ${summary}=    Catenate    SEPARATOR=\n    ${summary}    VM: ${vm_name} (${status})\n${stdout}
            ${tmpfile}=    Generate Random String    8
            ${tmpfile_path}=    Set Variable    vm_mem_stdout_${tmpfile}.txt
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
                    ...    observed_at=${timestamp}
                END
            END
        END
    END
    RW.Core.Add Pre To Report    ${summary}

Check Uptime for VMs in Resource Group `${AZ_RESOURCE_GROUP}`
    [Documentation]    Checks uptime for VMs and parses each result.
    [Tags]    access:read-only    VM    Azure    Uptime    Health
    ${uptime_usage}=    RW.CLI.Run Bash File
    ...    bash_file=vm_uptime_check.sh
    ...    env=${env}
    ...    timeout_seconds=300
    ...    include_in_history=false
    ...    extra_env=VM_INCLUDE_LIST,VM_OMIT_LIST,MAX_PARALLEL_JOBS,TIMEOUT_SECONDS
    ${timestamp}=    Datetime.Get Current Date

    # Check if Azure authentication failed completely
    ${auth_failed}=    Run Keyword And Return Status    Should Contain    ${uptime_usage.stdout}    Azure authentication failed
    IF    ${auth_failed}
        RW.Core.Add Issue    
            ...    title=Azure Authentication Failed for Resource Group `${AZ_RESOURCE_GROUP}` (Subscription: `${AZURE_SUBSCRIPTION_NAME}`)
            ...    severity=4
            ...    next_steps=Check Azure credentials for Resource Group `${AZ_RESOURCE_GROUP}`
            ...    expected=Azure CLI should authenticate successfully
            ...    actual=Azure authentication failed for subscription ${AZURE_RESOURCE_SUBSCRIPTION_ID}
            ...    reproduce_hint=Run: az account show --subscription ${AZURE_RESOURCE_SUBSCRIPTION_ID}
            ...    details={"error": "Azure authentication failed", "subscription": "${AZURE_RESOURCE_SUBSCRIPTION_ID}", "resource_group": "${AZ_RESOURCE_GROUP}"}
            ...    observed_at=${timestamp}
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
            ...    Virtual Machine `${vm_name}` (RG: `${AZ_RESOURCE_GROUP}`) is not running (Subscription: `${AZURE_SUBSCRIPTION_NAME}`)
            ...    Virtual Machine `${vm_name}` (RG: `${AZ_RESOURCE_GROUP}`) has connection issues (Subscription: `${AZURE_SUBSCRIPTION_NAME}`)
            ${next_steps}=    Set Variable If    "${code}" == "VMNotRunning"
            ...    Start VM `${vm_name}` in resource group `${AZ_RESOURCE_GROUP}`
            ...    Check Azure connectivity for VM `${vm_name}` in resource group `${AZ_RESOURCE_GROUP}`
            
            RW.Core.Add Issue    
                ...    title=${issue_title}
                ...    severity=${severity}
                ...    next_steps=${next_steps}
                ...    expected=VM should be accessible and running
                ...    actual=${stderr}
                ...    reproduce_hint=Run vm_uptime_check.sh or check VM status
                ...    details=${vm_data}
                ...    observed_at=${timestamp}
            ${summary}=    Catenate    SEPARATOR=\n    ${summary}    VM: ${vm_name} (${status}) - ${stderr}
        ELSE IF    "${code}" in ["WindowsVM", "NotIncluded", "Omitted"]
            ${issue_title}=    Set Variable If    "${code}" == "WindowsVM"    
            ...    Virtual Machine `${vm_name}` (RG: `${AZ_RESOURCE_GROUP}`) is a Windows VM and was skipped (Subscription: `${AZURE_SUBSCRIPTION_NAME}`)
            ...    Virtual Machine `${vm_name}` (RG: `${AZ_RESOURCE_GROUP}`) was filtered out by VM filtering rules (Subscription: `${AZURE_SUBSCRIPTION_NAME}`)
            ${next_steps}=    Set Variable If    "${code}" == "WindowsVM"
            ...    No action required - Windows VMs are not supported by Linux health checks
            ...    Review VM_INCLUDE_LIST and VM_OMIT_LIST configuration if this VM should be included
            
            RW.Core.Add Issue    
                ...    title=${issue_title}
                ...    severity=4
                ...    next_steps=${next_steps}
                ...    expected=VM filtering working as configured
                ...    actual=${stderr}
                ...    reproduce_hint=Run vm_uptime_check.sh or check VM filtering configuration
                ...    details=${vm_data}
                ...    observed_at=${timestamp}
            ${summary}=    Catenate    SEPARATOR=\n    ${summary}    VM: ${vm_name} (${status}) - ${stderr}
        ELSE IF    "${stderr}" != ""
            RW.Core.Add Issue    
                ...    title=Virtual Machine `${vm_name}` (RG: `${AZ_RESOURCE_GROUP}`) has uptime check errors (Subscription: `${AZURE_SUBSCRIPTION_NAME}`)
                ...    severity=1
                ...    next_steps=Investigate the error: ${stderr}
                ...    expected=No errors should occur during uptime check
                ...    actual=${stderr}
                ...    reproduce_hint=Run vm_uptime_check.sh
                ...    details=${vm_data}
                ...    observed_at=${timestamp}
            ${summary}=    Catenate    SEPARATOR=\n    ${summary}    VM: ${vm_name} (${status}) - Error: ${stderr}
        ELSE
            ${summary}=    Catenate    SEPARATOR=\n    ${summary}    VM: ${vm_name} (${status})\n${stdout}
            ${tmpfile}=    Generate Random String    8
            ${tmpfile_path}=    Set Variable    vm_uptime_stdout_${tmpfile}.txt
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
                    ...    observed_at=${timestamp}
                END
            END
        END
    END
    RW.Core.Add Pre To Report    ${summary}

Check Last Patch Status for VMs in Resource Group `${AZ_RESOURCE_GROUP}`
    [Documentation]    Checks last patch status for VMs and parses each result.
    [Tags]    access:read-only    VM    Azure    Patch    Health
    ${patch_usage}=    RW.CLI.Run Bash File
    ...    bash_file=vm_last_patch_check.sh
    ...    env=${env}
    ...    timeout_seconds=300
    ...    include_in_history=false
    ...    extra_env=VM_INCLUDE_LIST,VM_OMIT_LIST,MAX_PARALLEL_JOBS,TIMEOUT_SECONDS
    ${timestamp}=    Datetime.Get Current Date

    # Check if Azure authentication failed completely
    ${auth_failed}=    Run Keyword And Return Status    Should Contain    ${patch_usage.stdout}    Azure authentication failed
    IF    ${auth_failed}
        RW.Core.Add Issue    
            ...    title=Azure Authentication Failed for Resource Group `${AZ_RESOURCE_GROUP}` (Subscription: `${AZURE_SUBSCRIPTION_NAME}`)
            ...    severity=4
            ...    next_steps=Check Azure credentials for Resource Group `${AZ_RESOURCE_GROUP}`
            ...    expected=Azure CLI should authenticate successfully
            ...    actual=Azure authentication failed for subscription ${AZURE_RESOURCE_SUBSCRIPTION_ID}
            ...    reproduce_hint=Run: az account show --subscription ${AZURE_RESOURCE_SUBSCRIPTION_ID}
            ...    details={"error": "Azure authentication failed", "subscription": "${AZURE_RESOURCE_SUBSCRIPTION_ID}", "resource_group": "${AZ_RESOURCE_GROUP}"}
            ...    observed_at=${timestamp}
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
            ...    Virtual Machine `${vm_name}` (RG: `${AZ_RESOURCE_GROUP}`) is not running (Subscription: `${AZURE_SUBSCRIPTION_NAME}`)
            ...    Virtual Machine `${vm_name}` (RG: `${AZ_RESOURCE_GROUP}`) has connection issues (Subscription: `${AZURE_SUBSCRIPTION_NAME}`)
            ${next_steps}=    Set Variable If    "${code}" == "VMNotRunning"
            ...    Start VM `${vm_name}` in resource group `${AZ_RESOURCE_GROUP}`
            ...    Check Azure connectivity for VM `${vm_name}` in resource group `${AZ_RESOURCE_GROUP}`
            
            RW.Core.Add Issue    
                ...    title=${issue_title}
                ...    severity=${severity}
                ...    next_steps=${next_steps}
                ...    expected=VM should be accessible and running
                ...    actual=${stderr}
                ...    reproduce_hint=Run vm_last_patch_check.sh or check VM status
                ...    details=${vm_data}
                ...    observed_at=${timestamp}
            ${summary}=    Catenate    SEPARATOR=\n    ${summary}    VM: ${vm_name} (${status}) - ${stderr}
        ELSE IF    "${code}" in ["WindowsVM", "NotIncluded", "Omitted"]
            ${issue_title}=    Set Variable If    "${code}" == "WindowsVM"    
            ...    Virtual Machine `${vm_name}` (RG: `${AZ_RESOURCE_GROUP}`) is a Windows VM and was skipped (Subscription: `${AZURE_SUBSCRIPTION_NAME}`)
            ...    Virtual Machine `${vm_name}` (RG: `${AZ_RESOURCE_GROUP}`) was filtered out by VM filtering rules (Subscription: `${AZURE_SUBSCRIPTION_NAME}`)
            ${next_steps}=    Set Variable If    "${code}" == "WindowsVM"
            ...    No action required - Windows VMs are not supported by Linux health checks
            ...    Review VM_INCLUDE_LIST and VM_OMIT_LIST configuration if this VM should be included
            
            RW.Core.Add Issue    
                ...    title=${issue_title}
                ...    severity=4
                ...    next_steps=${next_steps}
                ...    expected=VM filtering working as configured
                ...    actual=${stderr}
                ...    reproduce_hint=Run vm_last_patch_check.sh or check VM filtering configuration
                ...    details=${vm_data}
                ...    observed_at=${timestamp}
            ${summary}=    Catenate    SEPARATOR=\n    ${summary}    VM: ${vm_name} (${status}) - ${stderr}
        ELSE IF    "${stderr}" != ""
            RW.Core.Add Issue    
                ...    title=Virtual Machine `${vm_name}` (RG: `${AZ_RESOURCE_GROUP}`) has patch check errors (Subscription: `${AZURE_SUBSCRIPTION_NAME}`)
                ...    severity=1
                ...    next_steps=Investigate the error: ${stderr}
                ...    expected=No errors should occur during patch check
                ...    actual=${stderr}
                ...    reproduce_hint=Run vm_last_patch_check.sh
                ...    details=${vm_data}
                ...    observed_at=${timestamp}
            ${summary}=    Catenate    SEPARATOR=\n    ${summary}    VM: ${vm_name} (${status}) - Error: ${stderr}
        ELSE
            ${summary}=    Catenate    SEPARATOR=\n    ${summary}    VM: ${vm_name} (${status})\n${stdout}
            ${tmpfile}=    Generate Random String    8
            ${tmpfile_path}=    Set Variable    vm_patch_stdout_${tmpfile}.txt
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
                    ...    observed_at=${timestamp}
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
    ${DISK_THRESHOLD}=    RW.Core.Import User Variable    DISK_THRESHOLD
    ...    type=string
    ...    description=The threshold percentage for disk usage warnings.
    ...    pattern=\d*
    ...    default=85
    ${UPTIME_THRESHOLD}=    RW.Core.Import User Variable    UPTIME_THRESHOLD
    ...    type=string
    ...    description=The threshold in days for system uptime warnings.
    ...    pattern=\d*
    ...    default=30
    ${MEMORY_THRESHOLD}=    RW.Core.Import User Variable    MEMORY_THRESHOLD
    ...    type=string
    ...    description=The threshold percentage for memory usage warnings.
    ...    pattern=\d*
    ...    default=90
    ${MAX_PARALLEL_JOBS}=    RW.Core.Import User Variable    MAX_PARALLEL_JOBS
    ...    type=string
    ...    description=Maximum number of parallel VM checks to run simultaneously.
    ...    pattern=\d*
    ...    default=5
    ${TIMEOUT_SECONDS}=    RW.Core.Import User Variable    TIMEOUT_SECONDS
    ...    type=string
    ...    description=Timeout in seconds for Azure VM run-command operations.
    ...    pattern=\d*
    ...    default=90
    ${VM_INCLUDE_LIST}=    RW.Core.Import User Variable    VM_INCLUDE_LIST
    ...    type=string
    ...    description=Comma-separated list of VM name patterns to include (e.g., "web-*,app-*"). If empty, all VMs are processed.
    ...    pattern=.*
    ${VM_OMIT_LIST}=    RW.Core.Import User Variable    VM_OMIT_LIST
    ...    type=string
    ...    description=Comma-separated list of VM name patterns to exclude (e.g., "test-*,dev-*"). If empty, no VMs are excluded.
    ...    pattern=.*
    ${AZURE_RESOURCE_SUBSCRIPTION_ID}=    RW.Core.Import User Variable    AZURE_SUBSCRIPTION_ID
    ...    type=string
    ...    description=The Azure Subscription ID.
    ...    pattern=\w*
    ${AZURE_SUBSCRIPTION_NAME}=    RW.Core.Import User Variable    AZURE_SUBSCRIPTION_NAME
    ...    type=string
    ...    description=The Azure Subscription Name.
    ...    pattern=\w*
    ...    default=subscription-01
    ${azure_credentials}=    RW.Core.Import Secret
    ...    azure_credentials
    ...    type=string
    ...    description=The secret containing AZURE_CLIENT_ID, AZURE_TENANT_ID, AZURE_CLIENT_SECRET, AZURE_SUBSCRIPTION_ID
    ...    pattern=\w*
    Set Suite Variable    ${AZ_RESOURCE_GROUP}    ${AZ_RESOURCE_GROUP}
    Set Suite Variable    ${DISK_THRESHOLD}    ${DISK_THRESHOLD}
    Set Suite Variable    ${UPTIME_THRESHOLD}    ${UPTIME_THRESHOLD}
    Set Suite Variable    ${MEMORY_THRESHOLD}    ${MEMORY_THRESHOLD}
    Set Suite Variable    ${MAX_PARALLEL_JOBS}    ${MAX_PARALLEL_JOBS}
    Set Suite Variable    ${TIMEOUT_SECONDS}    ${TIMEOUT_SECONDS}
    Set Suite Variable    ${VM_INCLUDE_LIST}    ${VM_INCLUDE_LIST}
    Set Suite Variable    ${VM_OMIT_LIST}    ${VM_OMIT_LIST}
    Set Suite Variable    ${AZURE_SUBSCRIPTION_NAME}    ${AZURE_SUBSCRIPTION_NAME}
    Set Suite Variable    ${AZURE_RESOURCE_SUBSCRIPTION_ID}    ${AZURE_RESOURCE_SUBSCRIPTION_ID}
    
    Set Suite Variable
    ...    ${env}
    ...    {"AZ_RESOURCE_GROUP":"${AZ_RESOURCE_GROUP}", "DISK_THRESHOLD": "${DISK_THRESHOLD}", "UPTIME_THRESHOLD": "${UPTIME_THRESHOLD}", "MEMORY_THRESHOLD": "${MEMORY_THRESHOLD}", "MAX_PARALLEL_JOBS": "${MAX_PARALLEL_JOBS}", "TIMEOUT_SECONDS": "${TIMEOUT_SECONDS}", "AZURE_SUBSCRIPTION_ID":"${AZURE_RESOURCE_SUBSCRIPTION_ID}", "AZURE_SUBSCRIPTION_NAME":"${AZURE_SUBSCRIPTION_NAME}"}
    # Set Azure subscription context
    RW.CLI.Run Cli
    ...    cmd=az account set --subscription ${AZURE_RESOURCE_SUBSCRIPTION_ID}
    ...    include_in_history=false