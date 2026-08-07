*** Settings ***
Documentation       Scores GCP Apigee API proxy health as a 0-1 value averaged across four dimensions: deployment health, environment coverage, revision state, and runtime status.
Metadata            Author    rw-codebundle-agent
Metadata            Display Name    GCP Apigee API Proxy Health
Metadata            Supports    GCP,Apigee,API Proxy,API Management
Force Tags          GCP    Apigee    API Proxy    API Management

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             OperatingSystem

Suite Setup         Suite Initialization

*** Tasks ***
Score Apigee Proxy Deployment Health in `${APIGEE_ORG}`
    [Documentation]    Scores 1.0 if no proxies are undeployed or running a stale revision, 0.0 otherwise.
    [Tags]    gcloud    apigee    deployment    gcp    ${APIGEE_ORG}    data:config    access:read-only
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check_deployments.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ${issues_output}=    RW.CLI.Run Cli
    ...    cmd=jq length deployment_issues.json 2>/dev/null || echo 0
    ...    env=${env}
    ${deployment_score}=    Evaluate    1 if int(${issues_output.stdout}) == 0 else 0
    Set Suite Variable    ${deployment_score}
    RW.Core.Push Metric    ${issues_output.stdout}    sub_name=deployment_issue_count
    RW.Core.Push Metric    ${deployment_score}    sub_name=deployment_health

Score Apigee Environment Deployment Coverage in `${APIGEE_ORG}`
    [Documentation]    Scores 1.0 if every environment has at least one active deployment, 0.0 otherwise.
    [Tags]    gcloud    apigee    environment    gcp    ${APIGEE_ORG}    data:config    access:read-only
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check_environment_coverage.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ${issues_output}=    RW.CLI.Run Cli
    ...    cmd=jq length coverage_issues.json 2>/dev/null || echo 0
    ...    env=${env}
    ${coverage_score}=    Evaluate    1 if int(${issues_output.stdout}) == 0 else 0
    Set Suite Variable    ${coverage_score}
    RW.Core.Push Metric    ${issues_output.stdout}    sub_name=empty_environment_count
    RW.Core.Push Metric    ${coverage_score}    sub_name=environment_coverage

Score Apigee Proxy Revision State in `${APIGEE_ORG}`
    [Documentation]    Scores 1.0 if no proxies are in draft state with un-promoted revisions, 0.0 otherwise.
    [Tags]    gcloud    apigee    revision    gcp    ${APIGEE_ORG}    data:config    access:read-only
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check_revisions.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ${issues_output}=    RW.CLI.Run Cli
    ...    cmd=jq length revision_issues.json 2>/dev/null || echo 0
    ...    env=${env}
    ${revision_score}=    Evaluate    1 if int(${issues_output.stdout}) == 0 else 0
    Set Suite Variable    ${revision_score}
    RW.Core.Push Metric    ${issues_output.stdout}    sub_name=revision_issue_count
    RW.Core.Push Metric    ${revision_score}    sub_name=revision_health

Score Apigee Runtime Environment Status in `${APIGEE_ORG}`
    [Documentation]    Scores 1.0 if all environments report an active runtime, 0.0 otherwise.
    [Tags]    gcloud    apigee    monitoring    gcp    ${APIGEE_ORG}    data:metrics    access:read-only
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check_runtime_status.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ${issues_output}=    RW.CLI.Run Cli
    ...    cmd=jq length runtime_issues.json 2>/dev/null || echo 0
    ...    env=${env}
    ${runtime_score}=    Evaluate    1 if int(${issues_output.stdout}) == 0 else 0
    Set Suite Variable    ${runtime_score}
    RW.Core.Push Metric    ${issues_output.stdout}    sub_name=inactive_environment_count
    RW.Core.Push Metric    ${runtime_score}    sub_name=runtime_health

Generate Aggregate Apigee Proxy Health Score for `${APIGEE_ORG}`
    [Documentation]    Averages the four dimension sub-scores into the final 0-1 health score.
    [Tags]    gcloud    apigee    gcp    ${APIGEE_ORG}    data:metrics    access:read-only
    ${health_score}=    Evaluate    (${deployment_score} + ${coverage_score} + ${revision_score} + ${runtime_score}) / 4
    ${health_score}=    Convert to Number    ${health_score}    2
    RW.Core.Add to Report    Apigee Proxy Health Score: ${health_score} -- deployment: ${deployment_score}, coverage: ${coverage_score}, revision: ${revision_score}, runtime: ${runtime_score}
    RW.Core.Push Metric    ${health_score}

*** Keywords ***
Suite Initialization
    ${gcp_credentials}=    RW.Core.Import Secret    gcp_credentials
    ...    type=string
    ...    description=GCP service account json used to authenticate with GCP and Apigee APIs.
    ...    pattern=\w*
    ...    example={"type": "service_account","project_id":"myproject-ID", ... super secret stuff ...}
    ${APIGEE_ORG}=    RW.Core.Import User Variable    APIGEE_ORG
    ...    type=string
    ...    description=The Apigee organization name hosting the API proxies to check.
    ...    pattern=\w*
    ...    example=my-apigee-org
    ${GCP_PROJECT_ID}=    RW.Core.Import User Variable    GCP_PROJECT_ID
    ...    type=string
    ...    description=The GCP Project ID hosting the Apigee runtime (used for authentication and Cloud Monitoring queries).
    ...    pattern=\w*
    ...    example=myproject-ID
    ${STALE_REVISION_THRESHOLD}=    RW.Core.Import User Variable    STALE_REVISION_THRESHOLD
    ...    type=string
    ...    description=Number of revisions behind latest before a proxy is flagged as stale.
    ...    pattern=^\d+$
    ...    default=1
    ${INCLUDE_DRAFT_PROXIES}=    RW.Core.Import User Variable    INCLUDE_DRAFT_PROXIES
    ...    type=string
    ...    description=Whether to include non-deployed/draft proxies as issues (true) or ignore them (false).
    ...    pattern=^(true|false)$
    ...    default=true
    ${METRIC_LOOKBACK_PERIOD}=    RW.Core.Import User Variable    METRIC_LOOKBACK_PERIOD
    ...    type=string
    ...    description=Cloud Monitoring lookback period for runtime metric queries (seconds).
    ...    pattern=^\d+s$
    ...    default=3600s
    Set Suite Variable    ${APIGEE_ORG}    ${APIGEE_ORG}
    Set Suite Variable    ${GCP_PROJECT_ID}    ${GCP_PROJECT_ID}
    Set Suite Variable    ${gcp_credentials}    ${gcp_credentials}
    Set Suite Variable    ${STALE_REVISION_THRESHOLD}    ${STALE_REVISION_THRESHOLD}
    Set Suite Variable    ${INCLUDE_DRAFT_PROXIES}    ${INCLUDE_DRAFT_PROXIES}
    Set Suite Variable    ${METRIC_LOOKBACK_PERIOD}    ${METRIC_LOOKBACK_PERIOD}
    ${OS_PATH}=    Get Environment Variable    PATH
    Set Suite Variable
    ...    ${env}
    ...    {"CLOUDSDK_CORE_PROJECT":"${GCP_PROJECT_ID}","PATH":"$PATH:${OS_PATH}","APIGEE_ORG":"${APIGEE_ORG}","GCP_PROJECT_ID":"${GCP_PROJECT_ID}","STALE_REVISION_THRESHOLD":"${STALE_REVISION_THRESHOLD}","INCLUDE_DRAFT_PROXIES":"${INCLUDE_DRAFT_PROXIES}","METRIC_LOOKBACK_PERIOD":"${METRIC_LOOKBACK_PERIOD}"}
    RW.CLI.Run CLI
    ...    cmd=gcloud auth activate-service-account --key-file="./${gcp_credentials.key}" || true
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
