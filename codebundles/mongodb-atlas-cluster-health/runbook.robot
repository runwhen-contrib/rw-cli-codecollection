*** Settings ***
Documentation       Read-only MongoDB Atlas Admin API v2 sweeps for clusters in a single project: topology inventory, operational state signals, and sampled workload metrics via digest-authenticated HTTPS.
Metadata            Author    rw-codebundle-agent
Metadata            Display Name    MongoDB Atlas Cluster Health
Metadata            Supports    MongoDB    Atlas    cluster    replication    metrics    observability

Force Tags          MongoDB    Atlas    cluster    health    metrics    read-only

Library             String
Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform

Suite Setup         Suite Initialization

*** Tasks ***
Gather MongoDB Atlas Cluster Inventory for Project `${ATLAS_PROJECT_ID}`
    [Documentation]    Lists Atlas clusters in the scoped project and summarizes edition, MongoDB versions, clouds, tiers, disks, paused flags, and transitional states operators need prior to narrowing incidents.
    [Tags]    MongoDB    Atlas    inventory    access:read-only    data:config

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=gather-atlas-cluster-inventory.sh
    ...    env=${env}
    ...    secret__atlas_api_key_credentials=${atlas_api_key_credentials}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=CLUSTER_FILTER="${CLUSTER_FILTER}" ./gather-atlas-cluster-inventory.sh

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat atlas_cluster_inventory_issues.json
    ...    timeout_seconds=30
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for Atlas inventory issues, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END

    ${inv_count}=    Get Length    ${issue_list}

    IF    ${inv_count} > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=Atlas inventory snapshots should expose healthy IDLE clusters aligned with Atlas UI realities.
            ...    actual=${issue['details']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END

    RW.Core.Add Pre To Report    Inventory summary:
    RW.Core.Add Pre To Report    ${result.stdout}

Check MongoDB Atlas Cluster State for Project `${ATLAS_PROJECT_ID}`
    [Documentation]    Evaluates paused clusters, transitional Atlas state enums, MongoDB replica process scopes, and healthStatus markers to pinpoint degradations before SLA breaches.
    [Tags]    MongoDB    Atlas    availability    replication    access:read-only    data:config

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check-atlas-cluster-state.sh
    ...    env=${env}
    ...    secret__atlas_api_key_credentials=${atlas_api_key_credentials}
    ...    timeout_seconds=240
    ...    include_in_history=false
    ...    cmd_override=CLUSTER_FILTER="${CLUSTER_FILTER}" ./check-atlas-cluster-state.sh

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat atlas_cluster_state_issues.json
    ...    timeout_seconds=30
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse Atlas cluster-state JSON payload, defaulting to empty issue list.    WARN
        ${issue_list}=    Create List
    END

    ${state_count}=    Get Length    ${issue_list}

    IF    ${state_count} > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=Clusters remain IDLE/MONGOS_ONLY with healthy replica topology or explicit Atlas maintenance windows without surprise downtime.
            ...    actual=${issue['details']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END

    RW.Core.Add Pre To Report    Operational state findings:
    RW.Core.Add Pre To Report    ${result.stdout}

Analyze MongoDB Atlas Cluster Metrics for Project `${ATLAS_PROJECT_ID}`
    [Documentation]    Pulls last~45 minute PT5 granular measurements for CONNECTIVITY_PERCENT, NORMALIZED_SYSTEM_CPU_USER, OPLOG-derived replication lag, and DISK PARTITION usage to compare against thresholds for noisy-neighbor workloads.
    [Tags]    MongoDB    Atlas    metrics    observability    access:read-only    data:metrics

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=analyze-atlas-cluster-metrics.sh
    ...    env=${env}
    ...    secret__atlas_api_key_credentials=${atlas_api_key_credentials}
    ...    timeout_seconds=280
    ...    include_in_history=false
    ...    cmd_override=CLUSTER_FILTER="${CLUSTER_FILTER}" ./analyze-atlas-cluster-metrics.sh

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat atlas_cluster_metrics_issues.json
    ...    timeout_seconds=30
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse Atlas metrics JSON payload.    WARN
        ${issue_list}=    Create List
    END

    ${metrics_count}=    Get Length    ${issue_list}

    IF    ${metrics_count} > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=Workload metrics remain under configured envelopes for connections, CPU, disks, and replica lag snapshots.
            ...    actual=${issue['details']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END

    RW.Core.Add Pre To Report    Metrics sweep output:
    RW.Core.Add Pre To Report    ${result.stdout}

*** Keywords ***
Suite Initialization
    TRY
        ${atlas_api_key_credentials}=    RW.Core.Import Secret    atlas_api_key_credentials
        ...    type=string
        ...    description=MongoDB Atlas programmatic API digest key serialized as JSON
        ...    pattern=\w*
        Set Suite Variable    ${atlas_api_key_credentials}    ${atlas_api_key_credentials}
    EXCEPT
        Log    atlas_api_key_credentials unavailable; Atlas API calls fail fast with structured issues.    WARN
        Set Suite Variable    ${atlas_api_key_credentials}    ${EMPTY}
    END

    ${ATLAS_PROJECT_ID}=    RW.Core.Import User Variable    ATLAS_PROJECT_ID
    ...    type=string
    ...    description=MongoDB Atlas project / group identifier (hex)
    ...    pattern=^[a-f0-9]{24}$
    ${ATLAS_ORG_ID}=    RW.Core.Import User Variable    ATLAS_ORG_ID
    ...    type=string
    ...    description=Optional Atlas organization identifier for audit annotations
    ...    pattern=^[a-fA-F0-9]{0,24}$
    ...    default=
    ${CLUSTER_FILTER}=    RW.Core.Import User Variable    CLUSTER_FILTER
    ...    type=string
    ...    description=Comma-separated Atlas cluster names; blank checks every cluster discovered in-project
    ...    pattern=^[\w\-, ]*$
    ...    default=
    ${CONNECTION_THRESHOLD}=    RW.Core.Import User Variable    CONNECTION_THRESHOLD
    ...    type=string
    ...    description=Issues when sampled CONNECTIONS_PERCENT exceeds this utilization percent
    ...    pattern=^\d+$
    ...    default=85
    ${DISK_UTIL_THRESHOLD}=    RW.Core.Import User Variable    DISK_UTIL_THRESHOLD
    ...    type=string
    ...    description=Issues when modeled disk occupancy exceeds this percent versus diskSizeGB
    ...    pattern=^\d+$
    ...    default=85
    ${REPLICATION_LAG_MS_THRESHOLD}=    RW.Core.Import User Variable    REPLICATION_LAG_MS_THRESHOLD
    ...    type=string
    ...    description=Issues when OPLOG_SLAVE_LAG_MASTER_TIME exceeds milliseconds value
    ...    pattern=^\d+$
    ...    default=5000
    ${CPU_UTIL_THRESHOLD}=    RW.Core.Import User Variable    CPU_UTIL_THRESHOLD
    ...    type=string
    ...    description=Issues when NORMALIZED_SYSTEM_CPU_USER maximum samples exceed percentage
    ...    pattern=^\d{1,3}$
    ...    default=92

    Set Suite Variable    ${ATLAS_PROJECT_ID}    ${ATLAS_PROJECT_ID}
    Set Suite Variable    ${ATLAS_ORG_ID}    ${ATLAS_ORG_ID}
    Set Suite Variable    ${CLUSTER_FILTER}    ${CLUSTER_FILTER}
    Set Suite Variable    ${CONNECTION_THRESHOLD}    ${CONNECTION_THRESHOLD}
    Set Suite Variable    ${DISK_UTIL_THRESHOLD}    ${DISK_UTIL_THRESHOLD}
    Set Suite Variable    ${REPLICATION_LAG_MS_THRESHOLD}    ${REPLICATION_LAG_MS_THRESHOLD}
    Set Suite Variable    ${CPU_UTIL_THRESHOLD}    ${CPU_UTIL_THRESHOLD}

    ${env}=    Create Dictionary
    ...    ATLAS_PROJECT_ID=${ATLAS_PROJECT_ID}
    ...    ATLAS_ORG_ID=${ATLAS_ORG_ID}
    ...    CLUSTER_FILTER=${CLUSTER_FILTER}
    ...    CONNECTION_THRESHOLD=${CONNECTION_THRESHOLD}
    ...    DISK_UTIL_THRESHOLD=${DISK_UTIL_THRESHOLD}
    ...    REPLICATION_LAG_MS_THRESHOLD=${REPLICATION_LAG_MS_THRESHOLD}
    ...    CPU_UTIL_THRESHOLD=${CPU_UTIL_THRESHOLD}
    Set Suite Variable    ${env}    ${env}
