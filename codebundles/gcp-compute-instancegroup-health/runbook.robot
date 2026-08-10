*** Settings ***
Documentation       Identify problems related to GCP Compute Engine instance groups (managed and unmanaged) at the group scope: member health, autoscaling, patch compliance, and utilization.
Metadata            Author    rw-codebundle-agent
Metadata            Display Name    GCP Compute Engine Instance Group Health
Metadata            Supports    GCP,Compute Engine,Instance Groups,Compute

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             OperatingSystem
Library             Collections

Suite Setup         Suite Initialization

Force Tags          GCP    Compute Engine    Instance Group    Health

*** Tasks ***
Discover GCP Instance Groups and Configurations in `${GCP_PROJECT_ID}`
    [Documentation]    Lists managed and unmanaged instance groups in the project, dumps group configuration (template, zones, target size, autoscaling settings), and identifies member instances.
    [Tags]    gcloud    gcp    instancegroup    access:read-only    data:config
    ${discover_result}=    RW.CLI.Run Bash File
    ...    bash_file=discover_instance_groups.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=INSTANCE_GROUP_NAME="${INSTANCE_GROUP_NAME}" ./discover_instance_groups.sh
    ${discover_issues}=    RW.CLI.Run Cli
    ...    cmd=cat instance_groups_issues.json
    ...    env=${env}
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${discover_issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for instance group discovery, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=${issue['expected']}
            ...    actual=${issue['actual']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${discover_result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    Instance Group Discovery Results:\n${discover_result.stdout}

Check Instance Group Member Health for `${INSTANCE_GROUP_NAME}`
    [Documentation]    Checks that all member instances of the group are in RUNNING/healthy state, flagging stopped, degraded, or re-creating instances.
    [Tags]    gcloud    gcp    instancegroup    access:read-only    data:metrics
    ${health_result}=    RW.CLI.Run Bash File
    ...    bash_file=check_group_member_health.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=INSTANCE_GROUP_NAME="${INSTANCE_GROUP_NAME}" ./check_group_member_health.sh
    ${health_issues}=    RW.CLI.Run Cli
    ...    cmd=cat group_member_health_issues.json
    ...    env=${env}
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${health_issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for member health, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=${issue['expected']}
            ...    actual=${issue['actual']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${health_result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    Instance Group Member Health Results:\n${health_result.stdout}

Check Instance Group Autoscaling and Capacity for `${INSTANCE_GROUP_NAME}`
    [Documentation]    For managed instance groups with autoscaling, verifies current size vs. target and flags autoscaler failures, unschedulable events, or groups unable to scale to meet demand.
    [Tags]    gcloud    gcp    instancegroup    access:read-only    data:metrics
    ${autoscale_result}=    RW.CLI.Run Bash File
    ...    bash_file=check_autoscaling.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=INSTANCE_GROUP_NAME="${INSTANCE_GROUP_NAME}" ./check_autoscaling.sh
    ${autoscale_issues}=    RW.CLI.Run Cli
    ...    cmd=cat group_autoscaling_issues.json
    ...    env=${env}
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${autoscale_issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for autoscaling, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=${issue['expected']}
            ...    actual=${issue['actual']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${autoscale_result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    Instance Group Autoscaling and Capacity Results:\n${autoscale_result.stdout}

Check Instance Group OS Patch Compliance for `${INSTANCE_GROUP_NAME}`
    [Documentation]    Uses GCP OS Config to check patch compliance across group members when available, flagging groups with pending or missing security patches beyond PATCH_WARNING_DAYS.
    [Tags]    gcloud    gcp    instancegroup    osconfig    access:read-only    data:logs-config
    ${patch_result}=    RW.CLI.Run Bash File
    ...    bash_file=check_group_patch_status.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=INSTANCE_GROUP_NAME="${INSTANCE_GROUP_NAME}" PATCH_WARNING_DAYS="${PATCH_WARNING_DAYS}" ./check_group_patch_status.sh
    ${patch_issues}=    RW.CLI.Run Cli
    ...    cmd=cat group_patch_issues.json
    ...    env=${env}
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${patch_issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for patch compliance, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=${issue['expected']}
            ...    actual=${issue['actual']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${patch_result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    Instance Group OS Patch Compliance Results:\n${patch_result.stdout}

Check Instance Group Utilization for `${INSTANCE_GROUP_NAME}`
    [Documentation]    Checks average CPU/disk utilization across group members via Cloud Monitoring, flagging groups that are consistently over- or under-utilized.
    [Tags]    gcloud    gcp    instancegroup    monitoring    access:read-only    data:metrics
    ${utilization_result}=    RW.CLI.Run Bash File
    ...    bash_file=check_group_utilization.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=INSTANCE_GROUP_NAME="${INSTANCE_GROUP_NAME}" UTILIZATION_LOW_THRESHOLD="${UTILIZATION_LOW_THRESHOLD}" UTILIZATION_HIGH_THRESHOLD="${UTILIZATION_HIGH_THRESHOLD}" ./check_group_utilization.sh
    ${utilization_issues}=    RW.CLI.Run Cli
    ...    cmd=cat group_utilization_issues.json
    ...    env=${env}
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${utilization_issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for utilization, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=${issue['expected']}
            ...    actual=${issue['actual']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${utilization_result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    Instance Group Utilization Results:\n${utilization_result.stdout}

Generate Instance Group Health Summary for `${GCP_PROJECT_ID}`
    [Documentation]    Aggregates all group-level check findings into a consolidated health summary per instance group and an overall verdict.
    [Tags]    gcloud    gcp    instancegroup    access:read-only    data:logs-config
    ${summary_result}=    RW.CLI.Run Bash File
    ...    bash_file=generate_group_summary.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=INSTANCE_GROUP_NAME="${INSTANCE_GROUP_NAME}" ./generate_group_summary.sh
    ${summary_issues}=    RW.CLI.Run Cli
    ...    cmd=cat group_summary_issues.json
    ...    env=${env}
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${summary_issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for group summary, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=${issue['expected']}
            ...    actual=${issue['actual']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${summary_result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    Instance Group Health Summary:\n${summary_result.stdout}

*** Keywords ***
Suite Initialization
    ${gcp_credentials}=    RW.Core.Import Secret    gcp_credentials
    ...    type=string
    ...    description=GCP service account json used to authenticate with GCP APIs.
    ...    pattern=\w*
    ...    example={"type": "service_account","project_id":"myproject-ID", ... super secret stuff ...}
    ${GCP_PROJECT_ID}=    RW.Core.Import User Variable    GCP_PROJECT_ID
    ...    type=string
    ...    description=The GCP Project ID hosting the instance groups.
    ...    pattern=\w*
    ...    example=myproject-ID
    ${INSTANCE_GROUP_NAME}=    RW.Core.Import User Variable    INSTANCE_GROUP_NAME
    ...    type=string
    ...    description=Name of the instance group to check. Set to "All" to inspect all groups in the project.
    ...    pattern=\w*
    ...    default=All
    ${PATCH_WARNING_DAYS}=    RW.Core.Import User Variable    PATCH_WARNING_DAYS
    ...    type=string
    ...    description=Days a missing/pending OS patch in the group may go unremediated before alerting.
    ...    pattern=^\d+$
    ...    default=30
    ${UTILIZATION_LOW_THRESHOLD}=    RW.Core.Import User Variable    UTILIZATION_LOW_THRESHOLD
    ...    type=string
    ...    description=Average CPU utilization percentage below which a group is considered under-utilized.
    ...    pattern=^\d+$
    ...    default=5
    ${UTILIZATION_HIGH_THRESHOLD}=    RW.Core.Import User Variable    UTILIZATION_HIGH_THRESHOLD
    ...    type=string
    ...    description=Average CPU utilization percentage above which a group is considered over-utilized.
    ...    pattern=^\d+$
    ...    default=90
    ${OS_PATH}=    Get Environment Variable    PATH
    Set Suite Variable    ${GCP_PROJECT_ID}    ${GCP_PROJECT_ID}
    Set Suite Variable    ${INSTANCE_GROUP_NAME}    ${INSTANCE_GROUP_NAME}
    Set Suite Variable    ${PATCH_WARNING_DAYS}    ${PATCH_WARNING_DAYS}
    Set Suite Variable    ${UTILIZATION_LOW_THRESHOLD}    ${UTILIZATION_LOW_THRESHOLD}
    Set Suite Variable    ${UTILIZATION_HIGH_THRESHOLD}    ${UTILIZATION_HIGH_THRESHOLD}
    Set Suite Variable    ${gcp_credentials}    ${gcp_credentials}
    Set Suite Variable
    ...    ${env}
    ...    {"CLOUDSDK_CORE_PROJECT":"${GCP_PROJECT_ID}","PATH":"$PATH:${OS_PATH}", "GCP_PROJECT_ID":"${GCP_PROJECT_ID}", "INSTANCE_GROUP_NAME":"${INSTANCE_GROUP_NAME}", "PATCH_WARNING_DAYS":"${PATCH_WARNING_DAYS}", "UTILIZATION_LOW_THRESHOLD":"${UTILIZATION_LOW_THRESHOLD}", "UTILIZATION_HIGH_THRESHOLD":"${UTILIZATION_HIGH_THRESHOLD}"}
    RW.CLI.Run CLI
    ...    cmd=gcloud auth activate-service-account --key-file="./${gcp_credentials.key}" || true
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
