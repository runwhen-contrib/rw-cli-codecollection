*** Settings ***
Documentation       Measures VAST tenant storage health from capacity, QoS wait times, and latency. Produces a score between 0 and 1.
Metadata            Author    rw-codebundle-agent
Metadata            Display Name    VAST Data Tenant Storage Health SLI
Metadata            Supports    VAST    vast_data    tenant    storage

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform

Suite Setup         Suite Initialization

*** Keywords ***
Suite Initialization
    TRY
        ${vast_vms_credentials}=    RW.Core.Import Secret    vast_vms_credentials
        ...    type=string
        ...    description=VMS API authentication credentials (USERNAME/PASSWORD or API_TOKEN JSON)
        ...    pattern=\w*
        Set Suite Variable    ${vast_vms_credentials}    ${vast_vms_credentials}
    EXCEPT
        Log    vast_vms_credentials secret not found.    WARN
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
    ...    CAPACITY_THRESHOLD=${CAPACITY_THRESHOLD}
    ...    QOS_UTILIZATION_THRESHOLD=${QOS_UTILIZATION_THRESHOLD}
    ...    LATENCY_THRESHOLD_MS=${LATENCY_THRESHOLD_MS}
    Set Suite Variable    ${env}    ${env}
    Set Suite Variable    ${score_capacity}    0
    Set Suite Variable    ${score_qos}    0
    Set Suite Variable    ${score_latency}    0

*** Tasks ***
Score Tenant Capacity Utilization
    [Documentation]    Binary 1/0 score when tenant quota utilization is below CAPACITY_THRESHOLD.
    [Tags]    VAST    vast_data    sli    access:read-only    data:metrics
    ${out}=    RW.CLI.Run Bash File
    ...    bash_file=sli-vast-capacity-score.sh
    ...    env=${env}
    ...    secret__vast_vms_credentials=${vast_vms_credentials}
    ...    include_in_history=false
    ...    timeout_seconds=60
    TRY
        ${data}=    Evaluate    json.loads(r'''${out.stdout}''')    json
    EXCEPT
        Log    SLI capacity JSON parse failed; scoring 0.    WARN
        ${data}=    Create Dictionary    score=0
    END
    ${s}=    Set Variable    ${data.get('score', 0)}
    Set Suite Variable    ${score_capacity}    ${s}
    RW.Core.Push Metric    ${s}    sub_name=capacity

Score Tenant QoS Wait Times
    [Documentation]    Binary 1/0 score when QoS wait time metrics indicate no throttling.
    [Tags]    VAST    vast_data    sli    access:read-only    data:metrics
    ${out}=    RW.CLI.Run Bash File
    ...    bash_file=sli-vast-qos-score.sh
    ...    env=${env}
    ...    secret__vast_vms_credentials=${vast_vms_credentials}
    ...    include_in_history=false
    ...    timeout_seconds=60
    TRY
        ${data}=    Evaluate    json.loads(r'''${out.stdout}''')    json
    EXCEPT
        Log    SLI QoS JSON parse failed; scoring 0.    WARN
        ${data}=    Create Dictionary    score=0
    END
    ${s}=    Set Variable    ${data.get('score', 0)}
    Set Suite Variable    ${score_qos}    ${s}
    RW.Core.Push Metric    ${s}    sub_name=qos

Score Tenant Read Write Latency
    [Documentation]    Binary 1/0 score when tenant latency remains below LATENCY_THRESHOLD_MS.
    [Tags]    VAST    vast_data    sli    access:read-only    data:metrics
    ${out}=    RW.CLI.Run Bash File
    ...    bash_file=sli-vast-latency-score.sh
    ...    env=${env}
    ...    secret__vast_vms_credentials=${vast_vms_credentials}
    ...    include_in_history=false
    ...    timeout_seconds=60
    TRY
        ${data}=    Evaluate    json.loads(r'''${out.stdout}''')    json
    EXCEPT
        Log    SLI latency JSON parse failed; scoring 0.    WARN
        ${data}=    Create Dictionary    score=0
    END
    ${s}=    Set Variable    ${data.get('score', 0)}
    Set Suite Variable    ${score_latency}    ${s}
    RW.Core.Push Metric    ${s}    sub_name=latency

Generate Aggregate VAST Tenant Storage Health Score
    [Documentation]    Averages binary sub-scores into the primary 0-1 SLI metric.
    [Tags]    VAST    vast_data    sli    access:read-only    data:metrics
    ${health_score}=    Evaluate    (int(${score_capacity}) + int(${score_qos}) + int(${score_latency})) / 3.0
    ${health_score}=    Convert To Number    ${health_score}    2
    ${report_line}=    Set Variable    VAST tenant storage health score: ${health_score} [capacity=${score_capacity}, qos=${score_qos}, latency=${score_latency}]
    RW.Core.Add to Report    ${report_line}
    RW.Core.Push Metric    ${health_score}
