*** Settings ***
Documentation       Scores GCP Cloud Run service health as a 0-1 value: 1 only if every health dimension passes (no failed revisions, all services Ready with traffic on the latest revision, no troubled/aborted rollouts), 0 if any dimension is degraded.
Metadata            Author    rw-codebundle-agent
Metadata            Display Name    GCP Cloud Run Service Health
Metadata            Supports    GCP,Cloud Run

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             OperatingSystem

Force Tags          GCP    Cloud Run    cloudrun

Suite Setup         Suite Initialization

*** Tasks ***
Score Failed Cloud Run Revisions in GCP Project `${GCP_PROJECT_ID}`
    [Documentation]    Scores 1 if no Cloud Run revisions are in a non-Ready state, 0 otherwise.
    [Tags]    gcloud    cloudrun    gcp    ${GCP_PROJECT_ID}    access:read-only    data:config
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=list_failed_revisions.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat failed_revisions_issues.json | jq length
    ...    env=${env}
    ${revision_score}=    Evaluate    1 if int(${issues.stdout}) == 0 else 0
    Set Suite Variable    ${revision_score}
    RW.Core.Push Metric    ${issues.stdout}    sub_name=failed_revision_count
    RW.Core.Push Metric    ${revision_score}    sub_name=revision_health

Score Cloud Run Services Ready and Serving in GCP Project `${GCP_PROJECT_ID}`
    [Documentation]    Scores 1 if all Cloud Run services are Ready with traffic on their latest ready revision, 0 otherwise.
    [Tags]    gcloud    cloudrun    gcp    ${GCP_PROJECT_ID}    access:read-only    data:config
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check_services_serving.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat services_serving_issues.json | jq length
    ...    env=${env}
    ${serving_score}=    Evaluate    1 if int(${issues.stdout}) == 0 else 0
    Set Suite Variable    ${serving_score}
    RW.Core.Push Metric    ${issues.stdout}    sub_name=unhealthy_service_count
    RW.Core.Push Metric    ${serving_score}    sub_name=serving_health

Score Cloud Run Rollout Health in GCP Project `${GCP_PROJECT_ID}`
    [Documentation]    Scores 1 if no Cloud Run service is in a troubled or aborted rollout, 0 otherwise.
    [Tags]    gcloud    cloudrun    gcp    ${GCP_PROJECT_ID}    access:read-only    data:config
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check_rollouts.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat rollouts_issues.json | jq length
    ...    env=${env}
    ${rollout_score}=    Evaluate    1 if int(${issues.stdout}) == 0 else 0
    Set Suite Variable    ${rollout_score}
    RW.Core.Push Metric    ${issues.stdout}    sub_name=troubled_rollout_count
    RW.Core.Push Metric    ${rollout_score}    sub_name=rollout_health

Generate Aggregate Cloud Run Health Score for `${GCP_PROJECT_ID}`
    [Documentation]    Overall score is 1 only if every health dimension passes; 0 if any dimension is degraded.
    [Tags]    gcloud    cloudrun    gcp    ${GCP_PROJECT_ID}    access:read-only    data:metrics
    ${health_score}=    Evaluate    1 if (${revision_score} + ${serving_score} + ${rollout_score}) == 3 else 0
    ${health_score}=    Convert To Number    ${health_score}    2
    RW.Core.Add to Report    Cloud Run Service Health Score: ${health_score} -- revision_health: ${revision_score}, serving_health: ${serving_score}, rollout_health: ${rollout_score}
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
    ...    description=The GCP Project ID to scope the API to.
    ...    pattern=\w*
    ...    example=myproject-ID
    ${RESOURCES}=    RW.Core.Import User Variable    RESOURCES
    ...    type=string
    ...    description=Comma-separated Cloud Run service names to check, or 'All' for auto-discovery.
    ...    pattern=\w*
    ...    default=All
    ${OS_PATH}=    Get Environment Variable    PATH
    Set Suite Variable    ${GCP_PROJECT_ID}    ${GCP_PROJECT_ID}
    Set Suite Variable    ${gcp_credentials}    ${gcp_credentials}
    Set Suite Variable
    ...    ${env}
    ...    {"CLOUDSDK_CORE_PROJECT":"${GCP_PROJECT_ID}","PATH":"$PATH:${OS_PATH}", "GCP_PROJECT_ID":"${GCP_PROJECT_ID}", "RESOURCES":"${RESOURCES}"}
    RW.CLI.Run CLI
    ...    cmd=gcloud auth activate-service-account --key-file="./${gcp_credentials.key}" || true
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
