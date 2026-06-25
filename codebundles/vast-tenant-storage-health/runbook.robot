*** Settings ***
Documentation       Monitors per-tenant and per-view storage health on VAST Data including capacity, QoS throttling, latency, and configuration policies.
Metadata            Author    rw-codebundle-agent
Metadata            Display Name    VAST Data Tenant Storage Health
Metadata            Supports    VAST    vast_data    tenant    storage    QoS    capacity

Force Tags          VAST    vast_data    tenant    storage    health

Library             String
Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             Collections

Suite Setup         Suite Initialization

*** Tasks ***
Check Tenant Capacity Utilization for Tenant `${VAST_TENANT_NAME}` on Cluster `${VAST_CLUSTER_NAME}`
    [Documentation]    Compares tenant logical capacity and DRR against assigned quotas from /api/prometheusmetrics/tenants and /tenants/ REST endpoints.
    [Tags]    VAST    vast_data    tenant    capacity    access:read-only    data:metrics

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check-tenant-capacity.sh
    ...    env=${env}
    ...    secret__vast_vms_credentials=${vast_vms_credentials}
    ...    include_in_history=false
    ...    timeout_seconds=180
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=VAST_TENANT_NAME="${VAST_TENANT_NAME}" ./check-tenant-capacity.sh

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat tenant_capacity_issues.json
    ...    timeout_seconds=30
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for tenant capacity task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=Tenant capacity utilization should remain below configured threshold
            ...    actual=${issue['details']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    Tenant capacity (${VAST_TENANT_NAME}):\n${result.stdout}

Check View Volume Capacity for Tenant `${VAST_TENANT_NAME}` on Cluster `${VAST_CLUSTER_NAME}`
    [Documentation]    Identifies views approaching or exceeding capacity limits and detects full volumes blocking writes.
    [Tags]    VAST    vast_data    view    capacity    access:read-only    data:metrics

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check-view-capacity.sh
    ...    env=${env}
    ...    secret__vast_vms_credentials=${vast_vms_credentials}
    ...    include_in_history=false
    ...    timeout_seconds=180
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=VAST_TENANT_NAME="${VAST_TENANT_NAME}" ./check-view-capacity.sh

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat view_capacity_issues.json
    ...    timeout_seconds=30
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for view capacity task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=View logical capacity should remain below configured threshold
            ...    actual=${issue['details']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    View capacity (${VAST_TENANT_NAME}):\n${result.stdout}

Analyze Tenant IOPS and Bandwidth Against QoS Limits for Tenant `${VAST_TENANT_NAME}`
    [Documentation]    Evaluates read/write IOPS and bandwidth metrics versus configured QoS ceilings and detects sustained throttling.
    [Tags]    VAST    vast_data    tenant    QoS    access:read-only    data:metrics

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=analyze-tenant-qos.sh
    ...    env=${env}
    ...    secret__vast_vms_credentials=${vast_vms_credentials}
    ...    include_in_history=false
    ...    timeout_seconds=180
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=VAST_TENANT_NAME="${VAST_TENANT_NAME}" ./analyze-tenant-qos.sh

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat tenant_qos_issues.json
    ...    timeout_seconds=30
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for tenant QoS task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=Tenant IO should remain below configured QoS limits
            ...    actual=${issue['details']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    Tenant QoS (${VAST_TENANT_NAME}):\n${result.stdout}

Check QoS Wait Times and Throttling for Tenant `${VAST_TENANT_NAME}`
    [Documentation]    Inspects QoS wait time metrics and metadata IOPS limits to detect configurations limiting user throughput.
    [Tags]    VAST    vast_data    tenant    QoS    access:read-only    data:metrics

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check-qos-wait-times.sh
    ...    env=${env}
    ...    secret__vast_vms_credentials=${vast_vms_credentials}
    ...    include_in_history=false
    ...    timeout_seconds=180
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=VAST_TENANT_NAME="${VAST_TENANT_NAME}" ./check-qos-wait-times.sh

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat qos_wait_issues.json
    ...    timeout_seconds=30
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for QoS wait task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=QoS wait times should be minimal under normal load
            ...    actual=${issue['details']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    QoS wait times (${VAST_TENANT_NAME}):\n${result.stdout}

Check User and Permission Configuration for Tenant `${VAST_TENANT_NAME}`
    [Documentation]    Reviews tenant user/group policies, export permissions, and quota policies that may restrict client access or capacity.
    [Tags]    VAST    vast_data    tenant    config    access:read-only    data:config

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check-tenant-config.sh
    ...    env=${env}
    ...    secret__vast_vms_credentials=${vast_vms_credentials}
    ...    include_in_history=false
    ...    timeout_seconds=180
    ...    show_in_rwl_cheatsheet=false
    ...    cmd_override=VAST_TENANT_NAME="${VAST_TENANT_NAME}" ./check-tenant-config.sh

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat tenant_config_issues.json
    ...    timeout_seconds=30
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for tenant config task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=Tenant configuration should not block legitimate client access
            ...    actual=${issue['details']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    Tenant configuration (${VAST_TENANT_NAME}):\n${result.stdout}

Analyze Read Write Latency Anomalies for Tenant `${VAST_TENANT_NAME}`
    [Documentation]    Detects elevated read/write/metadata latency from tenant metrics indicating storage performance degradation or IO stalls.
    [Tags]    VAST    vast_data    tenant    latency    access:read-only    data:metrics

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=analyze-tenant-latency.sh
    ...    env=${env}
    ...    secret__vast_vms_credentials=${vast_vms_credentials}
    ...    include_in_history=false
    ...    timeout_seconds=180
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=VAST_TENANT_NAME="${VAST_TENANT_NAME}" ./analyze-tenant-latency.sh

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat tenant_latency_issues.json
    ...    timeout_seconds=30
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for tenant latency task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=Tenant read/write latency should remain below configured threshold
            ...    actual=${issue['details']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    Tenant latency (${VAST_TENANT_NAME}):\n${result.stdout}

Check Block Volume Health for Tenant `${VAST_TENANT_NAME}`
    [Documentation]    Monitors block volume IOPS, bandwidth, and latency via /api/prometheusmetrics/volumes for volumes not flowing data normally.
    [Tags]    VAST    vast_data    block    volume    access:read-only    data:metrics

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check-block-volume-health.sh
    ...    env=${env}
    ...    secret__vast_vms_credentials=${vast_vms_credentials}
    ...    include_in_history=false
    ...    timeout_seconds=180
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=VAST_TENANT_NAME="${VAST_TENANT_NAME}" ./check-block-volume-health.sh

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat block_volume_issues.json
    ...    timeout_seconds=30
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for block volume task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=Block volumes should report healthy IO and latency
            ...    actual=${issue['details']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    Block volume health (${VAST_TENANT_NAME}):\n${result.stdout}

*** Keywords ***
Suite Initialization
    TRY
        ${vast_vms_credentials}=    RW.Core.Import Secret    vast_vms_credentials
        ...    type=string
        ...    description=VMS API authentication credentials (USERNAME/PASSWORD or API_TOKEN JSON)
        ...    pattern=\w*
        Set Suite Variable    ${vast_vms_credentials}    ${vast_vms_credentials}
    EXCEPT
        Log    vast_vms_credentials secret not found; VMS API tasks will fail until configured.    WARN
        Set Suite Variable    ${vast_vms_credentials}    ${EMPTY}
    END

    ${VAST_VMS_ENDPOINT}=    RW.Core.Import User Variable    VAST_VMS_ENDPOINT
    ...    type=string
    ...    description=VMS REST API base URL
    ...    pattern=\S+
    ${VAST_CLUSTER_NAME}=    RW.Core.Import User Variable    VAST_CLUSTER_NAME
    ...    type=string
    ...    description=VAST cluster name for qualifier scoping
    ...    pattern=\S+
    ${VAST_TENANT_NAME}=    RW.Core.Import User Variable    VAST_TENANT_NAME
    ...    type=string
    ...    description=VAST tenant name used as SLX qualifier
    ...    pattern=\S+
    ${TENANTS}=    RW.Core.Import User Variable    TENANTS
    ...    type=string
    ...    description=Tenant name or All for auto-discovery during generation
    ...    pattern=\S+
    ...    default=All
    ${CAPACITY_THRESHOLD}=    RW.Core.Import User Variable    CAPACITY_THRESHOLD
    ...    type=string
    ...    description=Tenant/view capacity utilization percent threshold
    ...    pattern=^[0-9.]+$
    ...    default=85
    ${QOS_UTILIZATION_THRESHOLD}=    RW.Core.Import User Variable    QOS_UTILIZATION_THRESHOLD
    ...    type=string
    ...    description=Percent of QoS limit sustained that triggers throttling issue
    ...    pattern=^[0-9.]+$
    ...    default=90
    ${LATENCY_THRESHOLD_MS}=    RW.Core.Import User Variable    LATENCY_THRESHOLD_MS
    ...    type=string
    ...    description=Read/write latency milliseconds above which to raise issue
    ...    pattern=^[0-9.]+$
    ...    default=10

    ${env}=    Create Dictionary
    ...    VAST_VMS_ENDPOINT=${VAST_VMS_ENDPOINT}
    ...    VAST_CLUSTER_NAME=${VAST_CLUSTER_NAME}
    ...    VAST_TENANT_NAME=${VAST_TENANT_NAME}
    ...    TENANTS=${TENANTS}
    ...    CAPACITY_THRESHOLD=${CAPACITY_THRESHOLD}
    ...    QOS_UTILIZATION_THRESHOLD=${QOS_UTILIZATION_THRESHOLD}
    ...    LATENCY_THRESHOLD_MS=${LATENCY_THRESHOLD_MS}

    Set Suite Variable    ${VAST_VMS_ENDPOINT}    ${VAST_VMS_ENDPOINT}
    Set Suite Variable    ${VAST_CLUSTER_NAME}    ${VAST_CLUSTER_NAME}
    Set Suite Variable    ${VAST_TENANT_NAME}    ${VAST_TENANT_NAME}
    Set Suite Variable    ${TENANTS}    ${TENANTS}
    Set Suite Variable    ${CAPACITY_THRESHOLD}    ${CAPACITY_THRESHOLD}
    Set Suite Variable    ${QOS_UTILIZATION_THRESHOLD}    ${QOS_UTILIZATION_THRESHOLD}
    Set Suite Variable    ${LATENCY_THRESHOLD_MS}    ${LATENCY_THRESHOLD_MS}
    Set Suite Variable    ${env}    ${env}

    IF    '${TENANTS}' == 'All' and '${VAST_TENANT_NAME}' == ''
        ${disco}=    RW.CLI.Run Bash File
        ...    bash_file=discover-vast-tenants.sh
        ...    env=${env}
        ...    secret__vast_vms_credentials=${vast_vms_credentials}
        ...    include_in_history=false
        ...    timeout_seconds=120
        ...    show_in_rwl_cheatsheet=true
        ...    cmd_override=./discover-vast-tenants.sh
        TRY
            ${tenant_list}=    Evaluate    json.loads(r'''${disco.stdout}''')    json
        EXCEPT
            Log    Failed to parse tenant discovery JSON.    WARN
            ${tenant_list}=    Create List
        END
        ${n}=    Get Length    ${tenant_list}
        RW.Core.Add Pre To Report    Discovered ${n} tenant(s): ${tenant_list}
    END
