*** Settings ***
Documentation       Measures the health of standalone GCP Compute Engine VMs by scoring operational status/uptime, OS patch status, disk utilization, network health, and guest/serial console health. Produces a value between 0 (completely failing) and 1 (fully passing).
Metadata            Author    rw-codebundle-agent
Metadata            Display Name    GCP Compute Engine VM Health
Metadata            Supports    GCP    Compute    VM    Health

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             OperatingSystem
Library             Collections

Suite Setup         Suite Initialization

*** Tasks ***
Score VM Operational Status and Uptime for `${VM_NAME}`
    [Documentation]    Scores 1 if the target VM is RUNNING and has not exceeded UPTIME_WARNING_DAYS since its last start, 0 otherwise.
    [Tags]    gcloud    compute    vm    gcp    uptime    access:read-only    data:metrics
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check_uptime.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ${issues_output}=    RW.CLI.Run Cli
    ...    cmd=cat uptime_issues.json | jq length
    ...    env=${env}
    ${uptime_score}=    Evaluate    1 if int(${issues_output.stdout}) == 0 else 0
    Set Suite Variable    ${uptime_score}
    RW.Core.Push Metric    ${issues_output.stdout}    sub_name=uptime_issue_count
    RW.Core.Push Metric    ${uptime_score}    sub_name=uptime_status

Score VM OS Patch Status for `${VM_NAME}`
    [Documentation]    Scores 1 if the target VM has no affected (missing) security vulnerabilities or OS policy violations, 0 otherwise.
    [Tags]    gcloud    compute    vm    gcp    osconfig    patch    access:read-only    data:logs-config
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check_patch_status.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ${issues_output}=    RW.CLI.Run Cli
    ...    cmd=cat patch_issues.json | jq length
    ...    env=${env}
    ${patch_score}=    Evaluate    1 if int(${issues_output.stdout}) == 0 else 0
    Set Suite Variable    ${patch_score}
    RW.Core.Push Metric    ${issues_output.stdout}    sub_name=patch_issue_count
    RW.Core.Push Metric    ${patch_score}    sub_name=patch_status

Score VM Disk Utilization for `${VM_NAME}`
    [Documentation]    Scores 1 if no disk on the target VM exceeds DISK_USAGE_THRESHOLD percent and no disk is degraded, 0 otherwise.
    [Tags]    gcloud    compute    vm    gcp    disk    access:read-only    data:metrics
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check_disk_utilization.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ${issues_output}=    RW.CLI.Run Cli
    ...    cmd=cat disk_issues.json | jq length
    ...    env=${env}
    ${disk_score}=    Evaluate    1 if int(${issues_output.stdout}) == 0 else 0
    Set Suite Variable    ${disk_score}
    RW.Core.Push Metric    ${issues_output.stdout}    sub_name=disk_issue_count
    RW.Core.Push Metric    ${disk_score}    sub_name=disk_status

Score VM Network Health for `${VM_NAME}`
    [Documentation]    Scores 1 if the target VM has no network health issues (interfaces, firewall/tag consistency, packet loss), 0 otherwise.
    [Tags]    gcloud    compute    vm    gcp    network    access:read-only    data:metrics
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check_network_health.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ${issues_output}=    RW.CLI.Run Cli
    ...    cmd=cat network_issues.json | jq length
    ...    env=${env}
    ${network_score}=    Evaluate    1 if int(${issues_output.stdout}) == 0 else 0
    Set Suite Variable    ${network_score}
    RW.Core.Push Metric    ${issues_output.stdout}    sub_name=network_issue_count
    RW.Core.Push Metric    ${network_score}    sub_name=network_status

Score VM Guest and Serial Console Health for `${VM_NAME}`
    [Documentation]    Scores 1 if the target VM has no guest agent, boot, or serial console error patterns, 0 otherwise.
    [Tags]    gcloud    compute    vm    gcp    console    access:read-only    data:logs-config
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check_console_health.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ${issues_output}=    RW.CLI.Run Cli
    ...    cmd=cat console_issues.json | jq length
    ...    env=${env}
    ${console_score}=    Evaluate    1 if int(${issues_output.stdout}) == 0 else 0
    Set Suite Variable    ${console_score}
    RW.Core.Push Metric    ${issues_output.stdout}    sub_name=console_issue_count
    RW.Core.Push Metric    ${console_score}    sub_name=console_status

Generate Aggregate VM Health Score for `${GCP_PROJECT_ID}`
    [Documentation]    Averages the five health dimension sub-scores into the final 0-1 VM health score.
    [Tags]    gcloud    compute    vm    gcp    access:read-only    data:metrics
    ${health_score}=    Evaluate    (${uptime_score} + ${patch_score} + ${disk_score} + ${network_score} + ${console_score}) / 5
    ${health_score}=    Convert To Number    ${health_score}    2
    RW.Core.Add to Report    VM Health Score: ${health_score} (uptime: ${uptime_score}, patch: ${patch_score}, disk: ${disk_score}, network: ${network_score}, console: ${console_score})
    RW.Core.Push Metric    ${health_score}

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
    ...    description=Name of the standalone VM to score, or "All" to score every standalone VM in the project.
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
