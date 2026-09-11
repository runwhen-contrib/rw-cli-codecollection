*** Settings ***
Metadata          Author    rw-codebundle-agent
Documentation     Measures the health of an Auth0 tenant by scoring service availability, custom domain health, error-log spikes, login-failure anomalies, rate-limit signals, and log-stream delivery. Produces a value between 0 (completely failing) and 1 (fully passing).
Metadata          Display Name    Auth0 Tenant Service Health
Metadata          Supports    Auth0    tenant    health    monitoring
Suite Setup       Suite Initialization
Library           BuiltIn
Library           String
Library           Collections
Library           RW.Core
Library           RW.CLI
Library           RW.platform


*** Keywords ***
Suite Initialization
    TRY
        ${AUTH0_MGMT_CREDENTIALS}=    RW.Core.Import Secret    AUTH0_MGMT_CREDENTIALS
        ...    type=string
        ...    description=Auth0 Management API client credentials. JSON with client_id and client_secret, or a raw MAPI bearer token.
        ...    pattern=.*
        Set Suite Variable    ${AUTH0_MGMT_CREDENTIALS}    ${AUTH0_MGMT_CREDENTIALS}
    EXCEPT
        Log    AUTH0_MGMT_CREDENTIALS secret not provided; Auth0 API tasks will fail until configured.    WARN
        Set Suite Variable    ${AUTH0_MGMT_CREDENTIALS}    ${EMPTY}
    END
    ${AUTH0_TENANT}=    RW.Core.Import User Variable    AUTH0_TENANT
    ...    type=string
    ...    description=Auth0 tenant name (e.g. mytenant; the full domain mytenant.auth0.com is derived from it).
    ...    pattern=[a-zA-Z0-9-._]+
    ${LOG_LOOKBACK_HOURS}=    RW.Core.Import User Variable    LOG_LOOKBACK_HOURS
    ...    type=string
    ...    description=How far back to analyze tenant logs (hours).
    ...    pattern=^\d+$
    ...    default=24
    ${LOGIN_FAILURE_THRESHOLD}=    RW.Core.Import User Variable    LOGIN_FAILURE_THRESHOLD
    ...    type=string
    ...    description=Number of login failures within the lookback window to flag an anomaly.
    ...    pattern=^\d+$
    ...    default=50
    ${RATE_LIMIT_THRESHOLD_PCT}=    RW.Core.Import User Variable    RATE_LIMIT_THRESHOLD_PCT
    ...    type=string
    ...    description=Rate limit utilization % above which a warning issue is raised.
    ...    pattern=^\d+$
    ...    default=80
    ${CERT_EXPIRY_WARN_DAYS}=    RW.Core.Import User Variable    CERT_EXPIRY_WARN_DAYS
    ...    type=string
    ...    description=Days before custom-domain certificate expiry to raise a warning.
    ...    pattern=^\d+$
    ...    default=30
    Set Suite Variable    ${AUTH0_TENANT}    ${AUTH0_TENANT}
    Set Suite Variable    ${LOG_LOOKBACK_HOURS}    ${LOG_LOOKBACK_HOURS}
    Set Suite Variable    ${LOGIN_FAILURE_THRESHOLD}    ${LOGIN_FAILURE_THRESHOLD}
    Set Suite Variable    ${RATE_LIMIT_THRESHOLD_PCT}    ${RATE_LIMIT_THRESHOLD_PCT}
    Set Suite Variable    ${CERT_EXPIRY_WARN_DAYS}    ${CERT_EXPIRY_WARN_DAYS}

    ${env}=    Create Dictionary
    ...    AUTH0_TENANT=${AUTH0_TENANT}
    ...    LOG_LOOKBACK_HOURS=${LOG_LOOKBACK_HOURS}
    ...    LOGIN_FAILURE_THRESHOLD=${LOGIN_FAILURE_THRESHOLD}
    ...    RATE_LIMIT_THRESHOLD_PCT=${RATE_LIMIT_THRESHOLD_PCT}
    ...    CERT_EXPIRY_WARN_DAYS=${CERT_EXPIRY_WARN_DAYS}
    Set Suite Variable    ${env}    ${env}


*** Tasks ***
Compute and Score Auth0 Tenant Health Dimensions for Tenant `${AUTH0_TENANT}`
    [Documentation]    Runs the lightweight Auth0 tenant health scorer and parses the six binary dimension scores.
    [Tags]    access:read-only    data:metrics
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=sli-auth0-tenant-score.sh
    ...    env=${env}
    ...    secret__AUTH0_MGMT_CREDENTIALS=${AUTH0_MGMT_CREDENTIALS}
    ...    timeout_seconds=120
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=false
    ...    cmd_override=./sli-auth0-tenant-score.sh
    TRY
        ${scores}=    Evaluate    json.loads(r'''${result.stdout}''')    json
        ${score_availability}=    Convert To Integer    ${scores['service_availability']}
        ${score_custom_domains}=    Convert To Integer    ${scores['custom_domains']}
        ${score_error_logs}=    Convert To Integer    ${scores['error_logs']}
        ${score_login_failures}=    Convert To Integer    ${scores['login_failures']}
        ${score_rate_limits}=    Convert To Integer    ${scores['rate_limits']}
        ${score_log_streams}=    Convert To Integer    ${scores['log_streams']}
    EXCEPT
        Log    Failed to parse Auth0 tenant health scores. Defaulting all dimensions to 0.    WARN
        ${score_availability}=    Set Variable    0
        ${score_custom_domains}=    Set Variable    0
        ${score_error_logs}=    Set Variable    0
        ${score_login_failures}=    Set Variable    0
        ${score_rate_limits}=    Set Variable    0
        ${score_log_streams}=    Set Variable    0
    END
    Set Suite Variable    ${score_availability}
    Set Suite Variable    ${score_custom_domains}
    Set Suite Variable    ${score_error_logs}
    Set Suite Variable    ${score_login_failures}
    Set Suite Variable    ${score_rate_limits}
    Set Suite Variable    ${score_log_streams}
    RW.Core.Push Metric    ${score_availability}    sub_name=service_availability
    RW.Core.Push Metric    ${score_custom_domains}    sub_name=custom_domains
    RW.Core.Push Metric    ${score_error_logs}    sub_name=error_logs
    RW.Core.Push Metric    ${score_login_failures}    sub_name=login_failures
    RW.Core.Push Metric    ${score_rate_limits}    sub_name=rate_limits
    RW.Core.Push Metric    ${score_log_streams}    sub_name=log_streams

Generate Auth0 Tenant Aggregate Health Score for Tenant `${AUTH0_TENANT}`
    [Documentation]    Averages the six dimension sub-scores into a single 0-1 health metric used for alerting.
    [Tags]    access:read-only    data:metrics
    ${health_score}=    Evaluate    (${score_availability} + ${score_custom_domains} + ${score_error_logs} + ${score_login_failures} + ${score_rate_limits} + ${score_log_streams}) / 6
    ${health_score}=    Convert to Number    ${health_score}    2
    RW.Core.Add to Report    Auth0 tenant health score: ${health_score}
    RW.Core.Push Metric    ${health_score}