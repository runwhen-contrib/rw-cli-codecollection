*** Settings ***
Documentation       Measures MongoDB Atlas project reachability plus cluster IDLE posture and capped PRIMARY replicas for CONNECTIVITY_PERCENT / NORMALIZED CPU windows, collapsing them into one 0-1 mean health score sourced from atlas Admin API digest calls.
Metadata            Author    rw-codebundle-agent
Metadata            Display Name    MongoDB Atlas Cluster Health SLI
Metadata            Supports    MongoDB    Atlas    cluster    replication    metrics

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform

Suite Setup         Suite Initialization

*** Keywords ***
Suite Initialization
    TRY
        ${atlas_api_key_credentials}=    RW.Core.Import Secret    atlas_api_key_credentials
        ...    type=string
        ...    description=MongoDB Atlas API digest credential JSON blob
        ...    pattern=\w*
        Set Suite Variable    ${atlas_api_key_credentials}    ${atlas_api_key_credentials}
    EXCEPT
        Log    atlas_api_key_credentials unavailable; Atlas SLI scores zero everywhere.    WARN
        Set Suite Variable    ${atlas_api_key_credentials}    ${EMPTY}
    END

    ${ATLAS_PROJECT_ID}=    RW.Core.Import User Variable    ATLAS_PROJECT_ID
    ...    type=string
    ...    description=Atlas group/project hex id
    ...    pattern=^[a-f0-9]{24}$
    ${CLUSTER_FILTER}=    RW.Core.Import User Variable    CLUSTER_FILTER
    ...    type=string
    ...    description=Comma-separated Atlas cluster filters for SLI scope
    ...    pattern=^[\w\-, ]*$
    ...    default=
    ${CONNECTION_THRESHOLD}=    RW.Core.Import User Variable    CONNECTION_THRESHOLD
    ...    type=string
    ...    description=SLI rejects samples above CONNECTIONS_PERCENT
    ...    pattern=^\d+$
    ...    default=85
    ${CPU_UTIL_THRESHOLD}=    RW.Core.Import User Variable    CPU_UTIL_THRESHOLD
    ...    type=string
    ...    description=SLI rejects samples above NORMALIZED_SYSTEM_CPU_USER percent
    ...    pattern=^\d{1,3}$
    ...    default=92
    ${SLI_MAX_MEASUREMENT_PROCESSES}=    RW.Core.Import User Variable    SLI_MAX_MEASUREMENT_PROCESSES
    ...    type=string
    ...    description=Maximum PRIMARY measurements per SLI run to mitigate API throttling
    ...    pattern=^\d+$
    ...    default=8

    Set Suite Variable    ${ATLAS_PROJECT_ID}    ${ATLAS_PROJECT_ID}
    Set Suite Variable    ${CLUSTER_FILTER}    ${CLUSTER_FILTER}
    Set Suite Variable    ${CONNECTION_THRESHOLD}    ${CONNECTION_THRESHOLD}
    Set Suite Variable    ${CPU_UTIL_THRESHOLD}    ${CPU_UTIL_THRESHOLD}
    Set Suite Variable    ${SLI_MAX_MEASUREMENT_PROCESSES}    ${SLI_MAX_MEASUREMENT_PROCESSES}

    ${env}=    Create Dictionary
    ...    ATLAS_PROJECT_ID=${ATLAS_PROJECT_ID}
    ...    CLUSTER_FILTER=${CLUSTER_FILTER}
    ...    CONNECTION_THRESHOLD=${CONNECTION_THRESHOLD}
    ...    CPU_UTIL_THRESHOLD=${CPU_UTIL_THRESHOLD}
    ...    SLI_MAX_MEASUREMENT_PROCESSES=${SLI_MAX_MEASUREMENT_PROCESSES}
    Set Suite Variable    ${env}    ${env}

*** Tasks ***
Gather MongoDB Atlas SLI Signals and Emit Composite Score for Project `${ATLAS_PROJECT_ID}`
    [Documentation]    Runs capped digest-authenticated curls for cluster inventory and PRIMARY metric samples before averaging binary sub-metrics into the SLI heartbeat published for alerts.
    [Tags]    MongoDB    Atlas    sli    access:read-only    data:metrics

    ${runner}=    RW.CLI.Run Bash File
    ...    bash_file=sli-mongodb-atlas-quick-check.sh
    ...    env=${env}
    ...    secret__atlas_api_key_credentials=${atlas_api_key_credentials}
    ...    timeout_seconds=120
    ...    include_in_history=false
    ...    cmd_override=./sli-mongodb-atlas-quick-check.sh

    TRY
        ${scores_raw}=    RW.CLI.Run Cli
        ...    cmd=cat sli_mongodb_atlas_scores.json
        ...    timeout_seconds=15
        ${scores}=    Evaluate    json.loads(r'''${scores_raw.stdout}''')    json
    EXCEPT
        Log    Failed to decode SLI shim JSON output.    WARN
        ${scores}=    Create Dictionary
        ...    api_ok=0
        ...    clusters_stable=0
        ...    metrics_snapshot_ok=0
    END

    ${api_ok}=    Evaluate    int(scores['api_ok'])    scores=${scores}
    ${stable_ok}=    Evaluate    int(scores['clusters_stable'])    scores=${scores}
    ${metric_ok}=    Evaluate    int(scores['metrics_snapshot_ok'])    scores=${scores}

    RW.Core.Push Metric    ${api_ok}    sub_name=atlas_api_ok
    RW.Core.Push Metric    ${stable_ok}    sub_name=clusters_idle_ok
    RW.Core.Push Metric    ${metric_ok}    sub_name=metrics_sample_ok

    ${health}=    Evaluate    (${api_ok}+${stable_ok}+${metric_ok})/3.0
    ${health}=    Convert To Number    ${health}    2
    RW.Core.Add To Report    MongoDB Atlas quick health (${ATLAS_PROJECT_ID}): composite=${health}, api=${api_ok}, idle=${stable_ok}, metrics_sample=${metric_ok}.
    RW.Core.Push Metric    ${health}
