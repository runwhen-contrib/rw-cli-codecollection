*** Settings ***
Documentation       Scores GCP Apigee API proxy health as a 0-1 value averaged across three fast management-API dimensions: deployment state, revision drift, and failed/undeployed proxies.
Metadata            Author    rw-codebundle-agent
Metadata            Display Name    GCP Apigee API Proxy Deployment and Traffic Health
Metadata            Supports    GCP,Apigee,API Proxy,Health
Force Tags          GCP    Apigee    API Proxy    Health

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             OperatingSystem

Suite Setup         Suite Initialization

*** Tasks ***
Establish Apigee Discovery Baseline for `${APIGEE_ORG}`
    [Documentation]    Resolves the Apigee org and caches deployments/proxies. A run that cannot authenticate, cannot resolve the org, or cannot read deployment status reports a discovery issue, which forces every sub-score AND the aggregate to 0 -- a blind run must never be indistinguishable from a healthy one.
    [Tags]    gcloud    apigee    gcp    ${APIGEE_ORG}    data:config    access:read-only
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=discover_proxies.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=300
    # A MISSING file means discovery never completed, so it defaults to 1 issue
    # (not 0). Defaulting to 0 here is what makes an unrunnable check score green.
    ${discovery_output}=    RW.CLI.Run Cli
    ...    cmd=jq length apigee_discovery_issues.json 2>/dev/null || echo 1
    ...    env=${env}
    ${discovery_issue_count}=    Evaluate    int(${discovery_output.stdout or 1})
    ${discovery_ok}=    Evaluate    1 if ${discovery_issue_count} == 0 else 0
    Set Suite Variable    ${discovery_ok}
    RW.Core.Push Metric    ${discovery_ok}    sub_name=discovery_ok

Score Apigee Proxy Deployment State in `${APIGEE_ORG}`
    [Documentation]    Scores 1.0 if every proxy deployment is READY with an empty errors[] array, 0.0 otherwise or if discovery could not run.
    [Tags]    gcloud    apigee    gcp    ${APIGEE_ORG}    data:state    access:read-only
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check_deployment_state.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ${issues_output}=    RW.CLI.Run Cli
    ...    cmd=jq length deployment_state_issues.json 2>/dev/null || echo -1
    ...    env=${env}
    ${dep_count}=    Evaluate    int(${issues_output.stdout or -1})
    ${dep_score}=    Evaluate    1 if (${discovery_ok} == 1 and ${dep_count} == 0) else 0
    Set Suite Variable    ${dep_score}
    RW.Core.Push Metric    ${{max(${dep_count}, 0)}}    sub_name=bad_deployment_count
    RW.Core.Push Metric    ${dep_score}    sub_name=deployment_state

Score Apigee Revision Drift in `${APIGEE_ORG}`
    [Documentation]    Scores 1.0 if every proxy is on its latest revision across all environments with no cross-environment drift, 0.0 otherwise or if discovery could not run.
    [Tags]    gcloud    apigee    gcp    ${APIGEE_ORG}    data:state    access:read-only
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check_revision_drift.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ${issues_output}=    RW.CLI.Run Cli
    ...    cmd=jq length revision_drift_issues.json 2>/dev/null || echo -1
    ...    env=${env}
    ${drift_count}=    Evaluate    int(${issues_output.stdout or -1})
    ${drift_score}=    Evaluate    1 if (${discovery_ok} == 1 and ${drift_count} == 0) else 0
    Set Suite Variable    ${drift_score}
    RW.Core.Push Metric    ${{max(${drift_count}, 0)}}    sub_name=drift_issue_count
    RW.Core.Push Metric    ${drift_score}    sub_name=revision_drift

Score Apigee Failed and Undeployed Proxies in `${APIGEE_ORG}`
    [Documentation]    Scores 1.0 if no deployments failed and every proxy is deployed to at least one environment, 0.0 otherwise or if discovery could not run.
    [Tags]    gcloud    apigee    gcp    ${APIGEE_ORG}    data:state    access:read-only
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check_failed_deployments.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ${issues_output}=    RW.CLI.Run Cli
    ...    cmd=jq length failed_deployments_issues.json 2>/dev/null || echo -1
    ...    env=${env}
    ${fail_count}=    Evaluate    int(${issues_output.stdout or -1})
    ${fail_score}=    Evaluate    1 if (${discovery_ok} == 1 and ${fail_count} == 0) else 0
    Set Suite Variable    ${fail_score}
    RW.Core.Push Metric    ${{max(${fail_count}, 0)}}    sub_name=failed_undeployed_count
    RW.Core.Push Metric    ${fail_score}    sub_name=failed_deployments

Generate Aggregate Apigee Health Score for `${APIGEE_ORG}`
    [Documentation]    Averages the three dimension sub-scores into the final 0-1 health score. A discovery failure forces the aggregate to 0, matching every sub-score.
    [Tags]    gcloud    apigee    gcp    ${APIGEE_ORG}    data:metrics    access:read-only
    ${health_score}=    Evaluate    0 if ${discovery_ok} == 0 else (${dep_score} + ${drift_score} + ${fail_score}) / 3
    ${health_score}=    Convert to Number    ${health_score}    2
    RW.Core.Add to Report    Apigee Proxy Health Score: ${health_score} -- discovery_ok: ${discovery_ok}, deployment_state: ${dep_score}, revision_drift: ${drift_score}, failed_deployments: ${fail_score}
    RW.Core.Push Metric    ${health_score}

*** Keywords ***
Suite Initialization
    ${gcp_credentials}=    RW.Core.Import Secret    gcp_credentials
    ...    type=string
    ...    description=GCP service account JSON key used to authenticate with gcloud and authorize the Apigee REST API. Needs roles/apigee.readOnlyAdmin.
    ...    pattern=\w*
    ...    example={"type": "service_account","project_id":"myproject-ID", ... super secret stuff ...}
    ${GCP_PROJECT_ID}=    RW.Core.Import User Variable    GCP_PROJECT_ID
    ...    type=string
    ...    description=The GCP project ID that owns the Apigee organization.
    ...    pattern=\w*
    ...    example=myproject-ID
    ${APIGEE_ORG}=    RW.Core.Import User Variable    APIGEE_ORG
    ...    type=string
    ...    description=The Apigee organization name (organizations/{org}). If empty, resolved from GCP_PROJECT_ID.
    ...    pattern=\w*
    ...    example=my-apigee-org
    ${PROXIES}=    RW.Core.Import User Variable    PROXIES
    ...    type=string
    ...    description=Comma-separated API proxy names to scope, or 'All'.
    ...    pattern=\w*
    ...    default=All
    ${ENVIRONMENTS}=    RW.Core.Import User Variable    ENVIRONMENTS
    ...    type=string
    ...    description=Comma-separated environment names to scope, or 'All'.
    ...    pattern=\w*
    ...    default=All
    ${POLICY_ERROR_THRESHOLD}=    RW.Core.Import User Variable    POLICY_ERROR_THRESHOLD
    ...    type=string
    ...    description=Maximum acceptable policy_error rate (0.01 = 1%).
    ...    pattern=^\d*\.?\d+$
    ...    default=0.01
    ${TARGET_ERROR_THRESHOLD}=    RW.Core.Import User Variable    TARGET_ERROR_THRESHOLD
    ...    type=string
    ...    description=Maximum acceptable target_error rate (0.01 = 1%).
    ...    pattern=^\d*\.?\d+$
    ...    default=0.01
    ${LATENCY_MS_THRESHOLD}=    RW.Core.Import User Variable    LATENCY_MS_THRESHOLD
    ...    type=string
    ...    description=Maximum acceptable p95 total_response_time in ms.
    ...    pattern=^\d+$
    ...    default=5000
    ${OVERHEAD_MS_THRESHOLD}=    RW.Core.Import User Variable    OVERHEAD_MS_THRESHOLD
    ...    type=string
    ...    description=Maximum acceptable Apigee processing overhead in ms.
    ...    pattern=^\d+$
    ...    default=500
    ${AUTH_ERROR_RATE_THRESHOLD}=    RW.Core.Import User Variable    AUTH_ERROR_RATE_THRESHOLD
    ...    type=string
    ...    description=Maximum acceptable 401/403 rate.
    ...    pattern=^\d*\.?\d+$
    ...    default=0.02
    ${RATE_LIMIT_ERROR_THRESHOLD}=    RW.Core.Import User Variable    RATE_LIMIT_ERROR_THRESHOLD
    ...    type=string
    ...    description=Maximum acceptable 429 rate.
    ...    pattern=^\d*\.?\d+$
    ...    default=0.05
    ${ANALYTICS_WINDOW_MIN}=    RW.Core.Import User Variable    ANALYTICS_WINDOW_MIN
    ...    type=string
    ...    description=Analytics lookback window in minutes.
    ...    pattern=^\d+$
    ...    default=60
    ${APIGEE_MAX_STATUS_CALLS}=    RW.Core.Import User Variable    APIGEE_MAX_STATUS_CALLS
    ...    type=string
    ...    description=Maximum per-deployment runtime-status calls discovery may make. Deployments beyond this cap are reported as UNKNOWN, never as healthy.
    ...    pattern=^\d+$
    ...    default=250
    ${REVISION_ACCUMULATION_THRESHOLD}=    RW.Core.Import User Variable    REVISION_ACCUMULATION_THRESHOLD
    ...    type=string
    ...    description=Number of total revisions at which a proxy is flagged for housekeeping.
    ...    pattern=^\d+$
    ...    default=20
    Set Suite Variable    ${GCP_PROJECT_ID}    ${GCP_PROJECT_ID}
    Set Suite Variable    ${gcp_credentials}    ${gcp_credentials}
    Set Suite Variable    ${APIGEE_ORG}    ${APIGEE_ORG}
    Set Suite Variable    ${PROXIES}    ${PROXIES}
    Set Suite Variable    ${ENVIRONMENTS}    ${ENVIRONMENTS}
    Set Suite Variable    ${POLICY_ERROR_THRESHOLD}    ${POLICY_ERROR_THRESHOLD}
    Set Suite Variable    ${TARGET_ERROR_THRESHOLD}    ${TARGET_ERROR_THRESHOLD}
    Set Suite Variable    ${LATENCY_MS_THRESHOLD}    ${LATENCY_MS_THRESHOLD}
    Set Suite Variable    ${OVERHEAD_MS_THRESHOLD}    ${OVERHEAD_MS_THRESHOLD}
    Set Suite Variable    ${AUTH_ERROR_RATE_THRESHOLD}    ${AUTH_ERROR_RATE_THRESHOLD}
    Set Suite Variable    ${RATE_LIMIT_ERROR_THRESHOLD}    ${RATE_LIMIT_ERROR_THRESHOLD}
    Set Suite Variable    ${ANALYTICS_WINDOW_MIN}    ${ANALYTICS_WINDOW_MIN}
    Set Suite Variable    ${APIGEE_MAX_STATUS_CALLS}    ${APIGEE_MAX_STATUS_CALLS}
    Set Suite Variable    ${REVISION_ACCUMULATION_THRESHOLD}    ${REVISION_ACCUMULATION_THRESHOLD}
    ${OS_PATH}=    Get Environment Variable    PATH
    Set Suite Variable
    ...    ${env}
    ...    {"CLOUDSDK_CORE_PROJECT":"${GCP_PROJECT_ID}","PATH":"$PATH:${OS_PATH}","GCP_PROJECT_ID":"${GCP_PROJECT_ID}","APIGEE_ORG":"${APIGEE_ORG}","PROXIES":"${PROXIES}","ENVIRONMENTS":"${ENVIRONMENTS}","POLICY_ERROR_THRESHOLD":"${POLICY_ERROR_THRESHOLD}","TARGET_ERROR_THRESHOLD":"${TARGET_ERROR_THRESHOLD}","LATENCY_MS_THRESHOLD":"${LATENCY_MS_THRESHOLD}","OVERHEAD_MS_THRESHOLD":"${OVERHEAD_MS_THRESHOLD}","AUTH_ERROR_RATE_THRESHOLD":"${AUTH_ERROR_RATE_THRESHOLD}","RATE_LIMIT_ERROR_THRESHOLD":"${RATE_LIMIT_ERROR_THRESHOLD}","ANALYTICS_WINDOW_MIN":"${ANALYTICS_WINDOW_MIN}","APIGEE_MAX_STATUS_CALLS":"${APIGEE_MAX_STATUS_CALLS}","REVISION_ACCUMULATION_THRESHOLD":"${REVISION_ACCUMULATION_THRESHOLD}"}
    RW.CLI.Run CLI
    ...    cmd=gcloud auth activate-service-account --key-file="./${gcp_credentials.key}" || true
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
