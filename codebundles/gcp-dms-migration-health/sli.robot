*** Settings ***
Documentation       Measures DMS migration health using job state, recent operations, and CDC replication lag. Produces a value between 0 (failing) and 1 (healthy) as the mean of binary sub-scores.
Metadata            Author    rw-codebundle-agent
Metadata            Display Name    GCP DMS Migration Health SLI
Metadata            Supports    GCP DMS Database Migration

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             OperatingSystem

Suite Setup         Suite Initialization


*** Tasks ***
Score DMS Health for Project `${GCP_PROJECT_ID}` Region `${GCP_DMS_LOCATION}`
    [Documentation]    Runs a lightweight gcloud and Monitoring check to produce sub-metrics and an aggregate 0-1 health score.
    [Tags]    GCP    DMS    access:read-only    data:metrics

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=sli-dms-health.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=60
    ...    show_in_rwl_cheatsheet=false
    ...    cmd_override=./sli-dms-health.sh

    ${scores_raw}=    RW.CLI.Run Cli
    ...    cmd=cat sli_dms_scores.json
    ...    env=${env}
    ...    include_in_history=false

    TRY
        ${scores}=    Evaluate    json.loads(r'''${scores_raw.stdout}''')    json
        ${job_score}=    Convert To Number    ${scores['job_score']}
        ${ops_score}=    Convert To Number    ${scores['ops_score']}
        ${lag_score}=    Convert To Number    ${scores['lag_score']}
        RW.Core.Push Metric    ${job_score}    sub_name=job_state
        RW.Core.Push Metric    ${ops_score}    sub_name=operations
        RW.Core.Push Metric    ${lag_score}    sub_name=replication_lag
        ${health_score}=    Evaluate    (${job_score} + ${ops_score} + ${lag_score}) / 3
        ${health_score}=    Convert to Number    ${health_score}    3
        RW.Core.Add to Report    DMS health score: ${health_score} (job=${job_score}, ops=${ops_score}, lag=${lag_score})
        RW.Core.Push Metric    ${health_score}
    EXCEPT
        Log    SLI score JSON parse failed; defaulting to zero health.    WARN
        ${health_score}=    Convert To Number    0
        RW.Core.Add to Report    DMS health score: ${health_score} (parse error)
        RW.Core.Push Metric    ${health_score}
    END


*** Keywords ***
Suite Initialization
    ${gcp_credentials}=    RW.Core.Import Secret    gcp_credentials
    ...    type=string
    ...    description=GCP service account JSON with read-only access to DMS and Monitoring.
    ...    pattern=\w*
    ${GCP_PROJECT_ID}=    RW.Core.Import User Variable    GCP_PROJECT_ID
    ...    type=string
    ...    description=GCP project ID for DMS resources.
    ...    pattern=\w*
    ${GCP_DMS_LOCATION}=    RW.Core.Import User Variable    GCP_DMS_LOCATION
    ...    type=string
    ...    description=DMS regional location (gcloud --region).
    ...    pattern=\w*
    ${REPLICATION_LAG_SEC_THRESHOLD}=    RW.Core.Import User Variable    REPLICATION_LAG_SEC_THRESHOLD
    ...    type=string
    ...    description=Maximum acceptable CDC replication lag in seconds for the SLI lag dimension.
    ...    pattern=^\d+$
    ...    default=300
    ${PATH_VAL}=    Get Environment Variable    PATH
    Set Suite Variable    ${GCP_PROJECT_ID}    ${GCP_PROJECT_ID}
    Set Suite Variable    ${GCP_DMS_LOCATION}    ${GCP_DMS_LOCATION}
    Set Suite Variable    ${REPLICATION_LAG_SEC_THRESHOLD}    ${REPLICATION_LAG_SEC_THRESHOLD}
    Set Suite Variable    ${gcp_credentials}    ${gcp_credentials}
    ${env}=    Create Dictionary
    ...    GCP_PROJECT_ID=${GCP_PROJECT_ID}
    ...    GCP_DMS_LOCATION=${GCP_DMS_LOCATION}
    ...    REPLICATION_LAG_SEC_THRESHOLD=${REPLICATION_LAG_SEC_THRESHOLD}
    ...    CLOUDSDK_CORE_PROJECT=${GCP_PROJECT_ID}
    ...    GOOGLE_APPLICATION_CREDENTIALS=./${gcp_credentials.key}
    ...    PATH=${PATH_VAL}
    Set Suite Variable    ${env}    ${env}
