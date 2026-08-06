*** Settings ***
Documentation       Measures VAST cluster health across five binary dimensions (VMS clustered, capacity, nodes, alarms, replication) and averages them into a 0-1 score.
Metadata            Author    rw-codebundle-agent
Metadata            Display Name    VAST Data Cluster Health SLI
Metadata            Supports    VAST    vast_data    cluster    storage    metrics

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform

Suite Setup         Suite Initialization


*** Tasks ***
Score VMS Cluster State
    [Documentation]    Binary score: 1 when vms_state=1 or cluster REST state is ONLINE/CLUSTERED, 0 otherwise.
    [Tags]    VAST    sli    access:read-only    data:metrics
    ${score}=    Set Variable    ${score_vms}
    RW.Core.Push Metric    ${score}    sub_name=vms_clustered

Score Cluster Capacity Headroom
    [Documentation]    Binary score: 1 when physical and logical utilization are below CAPACITY_THRESHOLD.
    [Tags]    VAST    sli    access:read-only    data:metrics
    ${score}=    Set Variable    ${score_capacity}
    RW.Core.Push Metric    ${score}    sub_name=capacity_ok

Score Node Hardware Health
    [Documentation]    Binary score: 1 when no CNodes or DNodes report offline/failed states.
    [Tags]    VAST    sli    access:read-only    data:metrics
    ${score}=    Set Variable    ${score_nodes}
    RW.Core.Push Metric    ${score}    sub_name=nodes_healthy

Score Active Alarm Clearance
    [Documentation]    Binary score: 1 when Prometheus alarms exporter reports no active alarms.
    [Tags]    VAST    sli    access:read-only    data:metrics
    ${score}=    Set Variable    ${score_alarms}
    RW.Core.Push Metric    ${score}    sub_name=alarms_clear

Score Replication Health
    [Documentation]    Binary score: 1 when replication Prometheus metrics show no failed/stalled streams (defaults to 1 if endpoint unavailable).
    [Tags]    VAST    sli    access:read-only    data:metrics
    ${score}=    Set Variable    ${score_replication}
    RW.Core.Push Metric    ${score}    sub_name=replication_ok

Generate Aggregate VAST Cluster Health Score
    [Documentation]    Averages sub-scores into the primary 0-1 health metric.
    [Tags]    VAST    sli    access:read-only    data:metrics
    ${total}=    Evaluate    int(${score_vms}) + int(${score_capacity}) + int(${score_nodes}) + int(${score_alarms}) + int(${score_replication})
    ${health_score}=    Evaluate    ${total} / 5.0
    ${health_score}=    Convert To Number    ${health_score}    2
    RW.Core.Add To Report    VAST cluster health score: ${health_score} (vms=${score_vms}, capacity=${score_capacity}, nodes=${score_nodes}, alarms=${score_alarms}, replication=${score_replication})
    RW.Core.Push Metric    ${health_score}


*** Keywords ***
Suite Initialization
    TRY
        ${vast_vms_credentials}=    RW.Core.Import Secret    vast_vms_credentials
        ...    type=string
        ...    description=VMS API credentials JSON with USERNAME/PASSWORD or API_TOKEN
        ...    pattern=\w*
        Set Suite Variable    ${vast_vms_credentials}    ${vast_vms_credentials}
    EXCEPT
        Log    vast_vms_credentials secret not found.    WARN
        Set Suite Variable    ${vast_vms_credentials}    ${EMPTY}
    END

    ${VAST_VMS_ENDPOINT}=    RW.Core.Import User Variable    VAST_VMS_ENDPOINT
    ...    type=string
    ...    description=VMS REST API base URL
    ...    pattern=\w*
    ${VAST_CLUSTER_NAME}=    RW.Core.Import User Variable    VAST_CLUSTER_NAME
    ...    type=string
    ...    description=VAST cluster display name
    ...    pattern=\w*
    ${CAPACITY_THRESHOLD}=    RW.Core.Import User Variable    CAPACITY_THRESHOLD
    ...    type=string
    ...    description=Capacity warning threshold percent
    ...    pattern=^\d+$
    ...    default=85
    ${CRITICAL_CAPACITY_THRESHOLD}=    RW.Core.Import User Variable    CRITICAL_CAPACITY_THRESHOLD
    ...    type=string
    ...    description=Critical capacity threshold percent
    ...    pattern=^\d+$
    ...    default=95

    Set Suite Variable    ${VAST_VMS_ENDPOINT}    ${VAST_VMS_ENDPOINT}
    Set Suite Variable    ${VAST_CLUSTER_NAME}    ${VAST_CLUSTER_NAME}
    Set Suite Variable    ${CAPACITY_THRESHOLD}    ${CAPACITY_THRESHOLD}
    Set Suite Variable    ${CRITICAL_CAPACITY_THRESHOLD}    ${CRITICAL_CAPACITY_THRESHOLD}

    ${cred_path}=    Set Variable If    '${vast_vms_credentials}' != ''    ./${vast_vms_credentials.key}    ${EMPTY}
    ${env_dict}=    Create Dictionary
    ...    VAST_VMS_ENDPOINT=${VAST_VMS_ENDPOINT}
    ...    VAST_CLUSTER_NAME=${VAST_CLUSTER_NAME}
    ...    CAPACITY_THRESHOLD=${CAPACITY_THRESHOLD}
    ...    CRITICAL_CAPACITY_THRESHOLD=${CRITICAL_CAPACITY_THRESHOLD}
    ...    VAST_VMS_CREDENTIALS_FILE=${cred_path}
    Set Suite Variable    ${env}    ${env_dict}

    Set Suite Variable    ${score_vms}    0
    Set Suite Variable    ${score_capacity}    0
    Set Suite Variable    ${score_nodes}    0
    Set Suite Variable    ${score_alarms}    0
    Set Suite Variable    ${score_replication}    1

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=sli-vast-cluster-health-score.sh
    ...    env=${env}
    ...    secret__vast_vms_credentials=${vast_vms_credentials}
    ...    timeout_seconds=30
    ...    include_in_history=false
    TRY
        ${data}=    Evaluate    json.loads(r'''${result.stdout}''')    json
        ${score_vms}=    Set Variable    ${data['vms_clustered']}
        ${score_capacity}=    Set Variable    ${data['capacity_ok']}
        ${score_nodes}=    Set Variable    ${data['nodes_healthy']}
        ${score_alarms}=    Set Variable    ${data['alarms_clear']}
        ${score_replication}=    Set Variable    ${data['replication_ok']}
    EXCEPT
        Log    Failed to parse SLI score JSON; defaulting sub-scores to failure mode.    WARN
    END
    Set Suite Variable    ${score_vms}    ${score_vms}
    Set Suite Variable    ${score_capacity}    ${score_capacity}
    Set Suite Variable    ${score_nodes}    ${score_nodes}
    Set Suite Variable    ${score_alarms}    ${score_alarms}
    Set Suite Variable    ${score_replication}    ${score_replication}
