*** Settings ***
Documentation       Monitors the health of standalone GCP Compute Engine VMs (instances not part of an instance group) covering uptime, OS patch status, disk utilization, network health, and guest/serial console health.
Metadata            Author    rw-codebundle-agent
Metadata            Display Name    GCP Compute Engine VM Health
Metadata            Supports    GCP    Compute    VM    Health    Uptime    Disk
Force Tags          GCP    Compute    VM    Health    Uptime    Disk

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             OperatingSystem
Library             Collections
Library             DateTime

Suite Setup         Suite Initialization

*** Tasks ***
Discover Standalone GCP Compute VMs in Project `${GCP_PROJECT_ID}`
    [Documentation]    Lists standalone VM instances in the project (excluding those that are members of an instance group) and dumps VM configuration; serves as the discovery input for the remaining per-VM checks.
    [Tags]    gcloud    compute    vm    gcp    ${GCP_PROJECT_ID}    access:read-only    data:config
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=discover_vms.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./discover_vms.sh
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat discovered_vms.json
    TRY
        ${vm_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse discovered VM list, defaulting to empty list.    WARN
        ${vm_list}=    Create List
    END
    IF    len(@{vm_list}) == 0
        RW.Core.Add Issue
        ...    severity=3
        ...    expected=At least one standalone compute VM should be discovered in project `${GCP_PROJECT_ID}`.
        ...    actual=No standalone compute VMs were discovered in project `${GCP_PROJECT_ID}`.
        ...    title=No standalone compute VMs discovered in project `${GCP_PROJECT_ID}`.
        ...    reproduce_hint=${result.cmd}
        ...    details=The discovery query returned no standalone VM instances. This may mean the project has no VMs, all VMs belong to instance groups, or the service account lacks permission to list compute instances.
        ...    next_steps=Verify project `${GCP_PROJECT_ID}` contains standalone VMs and that the service account has roles/compute.viewer.
    END
    RW.Core.Add Pre To Report    Discovered Compute VMs in ${GCP_PROJECT_ID}:\n${result.stdout}

Check VM Uptime and Operational Status for `${VM_NAME}`
    [Documentation]    Checks instance status and uptime for each target VM, flagging VMs running longer than UPTIME_WARNING_DAYS (too long since reboot) or in a degraded/non-running state.
    [Tags]    gcloud    compute    vm    gcp    uptime    ${GCP_PROJECT_ID}    access:read-only    data:metrics
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check_uptime.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./check_uptime.sh
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat uptime_issues.json
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse uptime issues JSON, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=${issue['expected']}
            ...    actual=${issue['actual']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    VM Uptime / Operational Status Analysis:\n${result.stdout}

Check VM OS Patch Status via OS Config for `${VM_NAME}`
    [Documentation]    Uses GCP OS Config to inspect patch and vulnerability compliance, flagging VMs with missing or pending security patches.
    [Tags]    gcloud    compute    vm    gcp    osconfig    patch    ${GCP_PROJECT_ID}    access:read-only    data:logs-config
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check_patch_status.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./check_patch_status.sh
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat patch_issues.json
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse patch issues JSON, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=${issue['expected']}
            ...    actual=${issue['actual']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    VM OS Patch Status Analysis:\n${result.stdout}

Check VM Disk Utilization for `${VM_NAME}`
    [Documentation]    Checks boot and attached disk utilization for each target VM, flagging disks that exceed DISK_USAGE_THRESHOLD percent full or are in a degraded state.
    [Tags]    gcloud    compute    vm    gcp    disk    ${GCP_PROJECT_ID}    access:read-only    data:metrics
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check_disk_utilization.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./check_disk_utilization.sh
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat disk_issues.json
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse disk issues JSON, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=${issue['expected']}
            ...    actual=${issue['actual']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    VM Disk Utilization Analysis:\n${result.stdout}

Check VM Network Health for `${VM_NAME}`
    [Documentation]    Verifies network health for each target VM including internal/external IP assignment, network tag and firewall consistency, and visible indicators of packet loss or traffic anomalies.
    [Tags]    gcloud    compute    vm    gcp    network    ${GCP_PROJECT_ID}    access:read-only    data:metrics
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check_network_health.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./check_network_health.sh
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat network_issues.json
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse network issues JSON, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=${issue['expected']}
            ...    actual=${issue['actual']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    VM Network Health Analysis:\n${result.stdout}

Check VM Guest and Serial Console Health for `${VM_NAME}`
    [Documentation]    Checks guest attributes, serial console output, and instance metadata for each target VM to detect guest agent issues, boot failures, or console errors.
    [Tags]    gcloud    compute    vm    gcp    console    ${GCP_PROJECT_ID}    access:read-only    data:logs-config
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check_console_health.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./check_console_health.sh
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat console_issues.json
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse console issues JSON, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=${issue['expected']}
            ...    actual=${issue['actual']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    VM Guest / Serial Console Health Analysis:\n${result.stdout}

*** Keywords ***
Suite Initialization
    ${gcp_credentials}=    RW.Core.Import Secret    gcp_credentials
    ...    type=string
    ...    description=GCP service account json used to authenticate with GCP APIs.
    ...    pattern=\w*
    ...    example={"type": "service_account","project_id":"myproject-ID", ... super secret stuff ...}
    ${GCP_PROJECT_ID}=    RW.Core.Import User Variable    GCP_PROJECT_ID
    ...    type=string
    ...    description=The GCP Project ID hosting the VMs.
    ...    pattern=\w*
    ...    example=myproject-ID
    ${VM_NAME}=    RW.Core.Import User Variable    VM_NAME
    ...    type=string
    ...    description=Name of the standalone VM to check, or "All" to scan every standalone VM in the project.
    ...    pattern=.*
    ...    default=All
    ${UPTIME_WARNING_DAYS}=    RW.Core.Import User Variable    UPTIME_WARNING_DAYS
    ...    type=string
    ...    description=Days a VM may run before a reboot is encouraged (uptime too long).
    ...    pattern=^\d+$
    ...    default=90
    ${PATCH_WARNING_DAYS}=    RW.Core.Import User Variable    PATCH_WARNING_DAYS
    ...    type=string
    ...    description=Days a missing or pending OS patch may go unremediated before alerting.
    ...    pattern=^\d+$
    ...    default=30
    ${DISK_USAGE_THRESHOLD}=    RW.Core.Import User Variable    DISK_USAGE_THRESHOLD
    ...    type=string
    ...    description=Disk usage percentage above which a disk is flagged as filling up.
    ...    pattern=^\d+$
    ...    default=85
    ${OS_PATH}=    Get Environment Variable    PATH
    Set Suite Variable    ${GCP_PROJECT_ID}    ${GCP_PROJECT_ID}
    Set Suite Variable    ${VM_NAME}    ${VM_NAME}
    Set Suite Variable    ${UPTIME_WARNING_DAYS}    ${UPTIME_WARNING_DAYS}
    Set Suite Variable    ${PATCH_WARNING_DAYS}    ${PATCH_WARNING_DAYS}
    Set Suite Variable    ${DISK_USAGE_THRESHOLD}    ${DISK_USAGE_THRESHOLD}
    Set Suite Variable    ${gcp_credentials}    ${gcp_credentials}
    Set Suite Variable
    ...    ${env}
    ...    {"CLOUDSDK_CORE_PROJECT":"${GCP_PROJECT_ID}","PATH":"$PATH:${OS_PATH}","GCP_PROJECT_ID":"${GCP_PROJECT_ID}","VM_NAME":"${VM_NAME}","UPTIME_WARNING_DAYS":"${UPTIME_WARNING_DAYS}","PATCH_WARNING_DAYS":"${PATCH_WARNING_DAYS}","DISK_USAGE_THRESHOLD":"${DISK_USAGE_THRESHOLD}"}
    RW.CLI.Run CLI
    ...    cmd=gcloud auth activate-service-account --key-file="./${gcp_credentials.key}" || true
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
