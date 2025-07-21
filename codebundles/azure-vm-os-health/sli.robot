*** Settings ***
Documentation       Calculates Azure VM health by checking disk, memory, uptime, and patch status.
Metadata            Author    Nbarola
Metadata            Display Name    Azure VM Health SLI
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
    ...    timeout_seconds=180
    ...    include_in_history=false

    ${disk_usg_out}=    Evaluate    json.loads(r'''${disk_usage.stdout}''')    json
    ${vm_names}=    Get Dictionary Keys    ${disk_usg_out}
    ${issue_count}=    Set Variable    0
    FOR    ${vm_name}    IN    @{vm_names}
        ${output}=    Get From Dictionary    ${disk_usg_out}    ${vm_name}
        # output is a dict, e.g. {'output': {...}}
        ${disk_output}=    Get From Dictionary    ${output}    output
        ${value_list}=    Get From Dictionary    ${disk_output}    value
        ${result}=    Get From List    ${value_list}    0
        ${message}=    Get From Dictionary    ${result}    message

        # Write message to a temp file
        ${tmpfile}=    Generate Random String    8
        ${tmpfile_path}=    Set Variable    /tmp/vm_disk_${tmpfile}.txt
        Create File    ${tmpfile_path}    ${message}

        # Parse the output using our invoke cmd parser
        ${parsed_out}=  Azure.Run Invoke Cmd Parser
        ...     input_file=${tmpfile_path}
        ...     timeout_seconds=60

        # Run next steps script and check for issues
        ${tmpfile2}=    Generate Random String    8
        ${tmpfile_path2}=    Set Variable    /tmp/vm_disk_stdout.txt
        Create File    ${tmpfile_path2}    ${parsed_out['stdout']}
        ${next_steps}=    RW.CLI.Run Bash File
        ...    bash_file=next_steps_disk_utilization.sh
        ...    env=${env}
        ...    timeout_seconds=180
        ...    include_in_history=false
        ${issues_list}=     RW.CLI.Run Cli
        ...     cmd=cat disk_utilization_issues.json
        ${issues}=    Evaluate    json.loads(r'''${issues_list.stdout}''')    json
        IF    len(@{issues}) > 0
            ${issue_count}=    Evaluate    ${issue_count} + 1
        END
    END
    ${disk_score}=    Evaluate    1 if ${issue_count} == 0 else 0
    Set Global Variable    ${disk_score}

Check Memory Utilization for VMs in Resource Group `${AZ_RESOURCE_GROUP}`
    [Documentation]    Checks memory utilization for VMs and parses each result.
    [Tags]    VM    Azure    Memory    Health
    ${memory_usage}=    RW.CLI.Run Bash File
    ...    bash_file=vm_memory_check.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false

    ${mem_usg_out}=    Evaluate    json.loads(r'''${memory_usage.stdout}''')    json
    ${vm_names}=    Get Dictionary Keys    ${mem_usg_out}
    ${issue_count}=    Set Variable    0
    FOR    ${vm_name}    IN    @{vm_names}
        ${output}=    Get From Dictionary    ${mem_usg_out}    ${vm_name}
        ${mem_output}=    Get From Dictionary    ${output}    output
        ${value_list}=    Get From Dictionary    ${mem_output}    value
        ${result}=    Get From List    ${value_list}    0
        ${message}=    Get From Dictionary    ${result}    message

        ${tmpfile}=    Generate Random String    8
        ${tmpfile_path}=    Set Variable    /tmp/vm_mem_${tmpfile}.txt
        Create File    ${tmpfile_path}    ${message}

        ${parsed_out}=  Azure.Run Invoke Cmd Parser
        ...     input_file=${tmpfile_path}
        ...     timeout_seconds=60

        ${tmpfile2}=    Generate Random String    8
        ${tmpfile_path2}=    Set Variable    /tmp/vm_mem_stdout.txt
        Create File    ${tmpfile_path2}    ${parsed_out['stdout']}
        ${next_steps}=    RW.CLI.Run Bash File
        ...    bash_file=next_steps_memory_check.sh
        ...    env=${env}
        ...    timeout_seconds=180
        ...    include_in_history=false
        ${issues_list}=     RW.CLI.Run Cli
        ...     cmd=cat memory_utilization_issues.json
        ${issues}=    Evaluate    json.loads(r'''${issues_list.stdout}''')    json
        IF    len(@{issues}) > 0
            ${issue_count}=    Evaluate    ${issue_count} + 1
        END
    END
    ${memory_score}=    Evaluate    1 if ${issue_count} == 0 else 0
    Set Global Variable    ${memory_score}

Check Uptime for VMs in Resource Group `${AZ_RESOURCE_GROUP}`
    [Documentation]    Checks uptime for VMs and parses each result.
    [Tags]    VM    Azure    Uptime    Health
    ${uptime_usage}=    RW.CLI.Run Bash File
    ...    bash_file=vm_uptime_check.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false

    ${uptime_usg_out}=    Evaluate    json.loads(r'''${uptime_usage.stdout}''')    json
    ${vm_names}=    Get Dictionary Keys    ${uptime_usg_out}
    ${issue_count}=    Set Variable    0
    FOR    ${vm_name}    IN    @{vm_names}
        ${output}=    Get From Dictionary    ${uptime_usg_out}    ${vm_name}
        ${uptime_output}=    Get From Dictionary    ${output}    output
        ${value_list}=    Get From Dictionary    ${uptime_output}    value
        ${result}=    Get From List    ${value_list}    0
        ${message}=    Get From Dictionary    ${result}    message

        ${tmpfile}=    Generate Random String    8
        ${tmpfile_path}=    Set Variable    /tmp/vm_uptime_${tmpfile}.txt
        Create File    ${tmpfile_path}    ${message}

        ${parsed_out}=  Azure.Run Invoke Cmd Parser
        ...     input_file=${tmpfile_path}
        ...     timeout_seconds=60

        ${tmpfile2}=    Generate Random String    8
        ${tmpfile_path2}=    Set Variable    /tmp/vm_uptime_stdout.txt
        Create File    ${tmpfile_path2}    ${parsed_out['stdout']}
        ${next_steps}=    RW.CLI.Run Bash File
        ...    bash_file=next_steps_uptime.sh
        ...    env=${env}
        ...    timeout_seconds=180
        ...    include_in_history=false
        ${issues_list}=     RW.CLI.Run Cli
        ...     cmd=cat uptime_issues.json
        ${issues}=    Evaluate    json.loads(r'''${issues_list.stdout}''')    json
        IF    len(@{issues}) > 0
            ${issue_count}=    Evaluate    ${issue_count} + 1
        END
    END
    ${uptime_score}=    Evaluate    1 if ${issue_count} == 0 else 0
    Set Global Variable    ${uptime_score}

Check Last Patch Status for VMs in Resource Group `${AZ_RESOURCE_GROUP}`
    [Documentation]    Checks last patch status for VMs and parses each result.
    [Tags]    VM    Azure    Patch    Health
    ${patch_usage}=    RW.CLI.Run Bash File
    ...    bash_file=vm_last_patch_check.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false

    ${patch_usg_out}=    Evaluate    json.loads(r'''${patch_usage.stdout}''')    json
    ${vm_names}=    Get Dictionary Keys    ${patch_usg_out}
    ${issue_count}=    Set Variable    0
    FOR    ${vm_name}    IN    @{vm_names}
        ${output}=    Get From Dictionary    ${patch_usg_out}    ${vm_name}
        ${patch_output}=    Get From Dictionary    ${output}    output
        ${value_list}=    Get From Dictionary    ${patch_output}    value
        ${result}=    Get From List    ${value_list}    0
        ${message}=    Get From Dictionary    ${result}    message

        ${tmpfile}=    Generate Random String    8
        ${tmpfile_path}=    Set Variable    /tmp/vm_patch_${tmpfile}.txt
        Create File    ${tmpfile_path}    ${message}

        ${parsed_out}=  Azure.Run Invoke Cmd Parser
        ...     input_file=${tmpfile_path}
        ...     timeout_seconds=60

        ${tmpfile2}=    Generate Random String    8
        ${tmpfile_path2}=    Set Variable    /tmp/vm_patch_stdout.txt
        Create File    ${tmpfile_path2}    ${parsed_out['stdout']}
        ${next_steps}=    RW.CLI.Run Bash File
        ...    bash_file=next_steps_patch_time.sh
        ...    env=${env}
        ...    timeout_seconds=180
        ...    include_in_history=false
        ${issues_list}=     RW.CLI.Run Cli
        ...     cmd=cat patch_issues.json
        ${issues}=    Evaluate    json.loads(r'''${issues_list.stdout}''')    json
        IF    len(@{issues}) > 0
            ${issue_count}=    Evaluate    ${issue_count} + 1
        END
    END
    ${patch_score}=    Evaluate    1 if ${issue_count} == 0 else 0
    Set Global Variable    ${patch_score}

Generate Comprehensive VM Health Score
    ${vm_health_score}=    Evaluate    (${disk_score} + ${memory_score} + ${uptime_score} + ${patch_score}) / 4
    ${health_score}=    Convert to Number    ${vm_health_score}    2
    RW.Core.Push Metric    ${health_score}

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
    # Set Azure subscription context
    RW.CLI.Run Cli
    ...    cmd=az account set --subscription ${AZURE_RESOURCE_SUBSCRIPTION_ID}
    ...    include_in_history=false