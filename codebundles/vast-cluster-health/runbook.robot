*** Settings ***
Documentation       Monitor VAST Data cluster-wide health via VMS REST and Prometheus exporter endpoints for degraded state, capacity pressure, hardware faults, and protocol performance.
Metadata            Author    rw-codebundle-agent
Metadata            Display Name    VAST Data Cluster Health
Metadata            Supports    VAST    vast_data    cluster    storage    metrics

Force Tags          VAST    vast_data    cluster    storage    health

Library             String
Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform

Suite Setup         Suite Initialization


*** Tasks ***
Check VMS Cluster Health Status for Cluster `${VAST_CLUSTER_NAME}`
    [Documentation]    Queries /api/prometheusmetrics/vms_state and VMS cluster status to detect DEGRADED (0) vs CLUSTERED (1) state and any active cluster alerts.
    [Tags]    VAST    vast_data    cluster    health    access:read-only    data:metrics

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check-vms-cluster-health.sh
    ...    env=${env}
    ...    secret__vast_vms_credentials=${vast_vms_credentials}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./check-vms-cluster-health.sh

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat vms_cluster_health_output.json

    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END

    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=VMS cluster health should report CLUSTERED/ONLINE state for cluster `${VAST_CLUSTER_NAME}`
            ...    actual=VMS cluster health check found degraded or unreachable cluster state
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END

    RW.Core.Add Pre To Report    VMS Cluster Health Results:\n${result.stdout}

Check Cluster Capacity Utilization for Cluster `${VAST_CLUSTER_NAME}`
    [Documentation]    Evaluates physical and logical capacity utilization from cluster REST and Prometheus metrics; raises issues when usage exceeds CAPACITY_THRESHOLD percent.
    [Tags]    VAST    vast_data    cluster    capacity    access:read-only    data:metrics

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check-cluster-capacity.sh
    ...    env=${env}
    ...    secret__vast_vms_credentials=${vast_vms_credentials}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./check-cluster-capacity.sh

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat cluster_capacity_output.json

    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END

    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=Cluster physical and logical capacity should remain below configured thresholds for cluster `${VAST_CLUSTER_NAME}`
            ...    actual=Cluster capacity utilization exceeds warning or critical thresholds
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END

    RW.Core.Add Pre To Report    Cluster Capacity Results:\n${result.stdout}

Check CNode and DNode Hardware Health for Cluster `${VAST_CLUSTER_NAME}`
    [Documentation]    Inspects CNode/DNode state, SSD/SCM health, and hardware fault indicators from REST and Prometheus exporter metrics.
    [Tags]    VAST    vast_data    cnodes    dnodes    hardware    access:read-only    data:metrics

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check-node-hardware-health.sh
    ...    env=${env}
    ...    secret__vast_vms_credentials=${vast_vms_credentials}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    cmd_override=./check-node-hardware-health.sh

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat node_hardware_health_output.json

    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END

    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=All CNodes, DNodes, and storage devices should be healthy for cluster `${VAST_CLUSTER_NAME}`
            ...    actual=Node or device hardware health issues were detected
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END

    RW.Core.Add Pre To Report    Node Hardware Health Results:\n${result.stdout}

Check Cluster Degraded Components and Active Alerts for Cluster `${VAST_CLUSTER_NAME}`
    [Documentation]    Lists degraded boxes, failed drives, offline nodes, and active VMS alerts that indicate partial cluster failure.
    [Tags]    VAST    vast_data    cluster    alerts    access:read-only    data:logs-config

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check-degraded-components.sh
    ...    env=${env}
    ...    secret__vast_vms_credentials=${vast_vms_credentials}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    cmd_override=./check-degraded-components.sh

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat degraded_components_output.json

    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END

    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=Cluster should have no degraded boxes, offline nodes, or active alarms for cluster `${VAST_CLUSTER_NAME}`
            ...    actual=Degraded components or active VMS alarms were found
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END

    RW.Core.Add Pre To Report    Degraded Components Results:\n${result.stdout}

Analyze Cluster Protocol Performance for Cluster `${VAST_CLUSTER_NAME}`
    [Documentation]    Reviews cluster-wide IOPS, bandwidth, and latency by storage protocol (NFS, block, S3) to detect IO stalls or abnormal drops in data flow.
    [Tags]    VAST    vast_data    cluster    performance    access:read-only    data:metrics

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=analyze-cluster-performance.sh
    ...    env=${env}
    ...    secret__vast_vms_credentials=${vast_vms_credentials}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    cmd_override=./analyze-cluster-performance.sh

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat cluster_performance_output.json

    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END

    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=Cluster protocol performance should remain within expected IO and latency bounds for cluster `${VAST_CLUSTER_NAME}`
            ...    actual=Cluster protocol performance anomalies were detected
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END

    RW.Core.Add Pre To Report    Cluster Performance Results:\n${result.stdout}

Check Replication and Protection Group Status for Cluster `${VAST_CLUSTER_NAME}`
    [Documentation]    Verifies replication links, protection groups, and snapshot policies are healthy and not blocking writes or causing capacity pressure.
    [Tags]    VAST    vast_data    cluster    replication    access:read-only    data:config

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check-replication-status.sh
    ...    env=${env}
    ...    secret__vast_vms_credentials=${vast_vms_credentials}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    cmd_override=./check-replication-status.sh

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat replication_status_output.json

    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END

    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=Replication streams and protection groups should be healthy with acceptable snapshot/auxiliary space for cluster `${VAST_CLUSTER_NAME}`
            ...    actual=Replication or protection group issues were detected
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END

    RW.Core.Add Pre To Report    Replication Status Results:\n${result.stdout}


*** Keywords ***
Suite Initialization
    TRY
        ${vast_vms_credentials}=    RW.Core.Import Secret    vast_vms_credentials
        ...    type=string
        ...    description=VMS API credentials JSON with USERNAME/PASSWORD or API_TOKEN
        ...    pattern=\w*
        Set Suite Variable    ${vast_vms_credentials}    ${vast_vms_credentials}
    EXCEPT
        Log    vast_vms_credentials secret not found; VMS API tasks will fail until configured.    WARN
        Set Suite Variable    ${vast_vms_credentials}    ${EMPTY}
    END

    ${VAST_VMS_ENDPOINT}=    RW.Core.Import User Variable    VAST_VMS_ENDPOINT
    ...    type=string
    ...    description=VMS REST API base URL (e.g. https://vms.example.com)
    ...    pattern=\w*
    ${VAST_CLUSTER_NAME}=    RW.Core.Import User Variable    VAST_CLUSTER_NAME
    ...    type=string
    ...    description=VAST cluster display name for scoping and issue titles
    ...    pattern=\w*
    ${RESOURCES}=    RW.Core.Import User Variable    RESOURCES
    ...    type=string
    ...    description=Cluster name(s) or All for auto-discovery via VMS API
    ...    pattern=^[\w,\s-]*$
    ...    default=All
    ${CAPACITY_THRESHOLD}=    RW.Core.Import User Variable    CAPACITY_THRESHOLD
    ...    type=string
    ...    description=Physical/logical capacity utilization percent that triggers an issue
    ...    pattern=^\d+$
    ...    default=85
    ${CRITICAL_CAPACITY_THRESHOLD}=    RW.Core.Import User Variable    CRITICAL_CAPACITY_THRESHOLD
    ...    type=string
    ...    description=Critical capacity threshold percent
    ...    pattern=^\d+$
    ...    default=95

    Set Suite Variable    ${VAST_VMS_ENDPOINT}    ${VAST_VMS_ENDPOINT}
    Set Suite Variable    ${VAST_CLUSTER_NAME}    ${VAST_CLUSTER_NAME}
    Set Suite Variable    ${RESOURCES}    ${RESOURCES}
    Set Suite Variable    ${CAPACITY_THRESHOLD}    ${CAPACITY_THRESHOLD}
    Set Suite Variable    ${CRITICAL_CAPACITY_THRESHOLD}    ${CRITICAL_CAPACITY_THRESHOLD}

    ${cred_path}=    Set Variable If    '${vast_vms_credentials}' != ''    ./${vast_vms_credentials.key}    ${EMPTY}
    ${env_dict}=    Create Dictionary
    ...    VAST_VMS_ENDPOINT=${VAST_VMS_ENDPOINT}
    ...    VAST_CLUSTER_NAME=${VAST_CLUSTER_NAME}
    ...    RESOURCES=${RESOURCES}
    ...    CAPACITY_THRESHOLD=${CAPACITY_THRESHOLD}
    ...    CRITICAL_CAPACITY_THRESHOLD=${CRITICAL_CAPACITY_THRESHOLD}
    ...    VAST_VMS_CREDENTIALS_FILE=${cred_path}
    Set Suite Variable    ${env}    ${env_dict}
