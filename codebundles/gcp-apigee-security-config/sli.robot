*** Settings ***
Documentation       Measures the health of Apigee security and configuration by scoring TLS keystore alias expiry, API product quota/rate limits, developer app access scope, security score, and target server TLS. Produces a value between 0 (completely failing) and 1 (fully passing).
Metadata            Author    rw-codebundle-agent
Metadata            Display Name    GCP Apigee Security and Configuration Health
Metadata            Supports    GCP,Apigee,Security
Suite Setup         Suite Initialization
Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             OperatingSystem
Library             Collections


*** Keywords ***
Suite Initialization
    ${gcp_credentials}=    RW.Core.Import Secret    gcp_credentials
    ...    type=string
    ...    description=GCP service account JSON key used to authenticate with Apigee Admin and Cloud Monitoring APIs.
    ...    pattern=\w*
    ...    example={"type": "service_account","project_id":"myproject-ID"}
    ${APIGEE_ORG}=    RW.Core.Import User Variable    APIGEE_ORG
    ...    type=string
    ...    description=Apigee organization name (security/config scope).
    ...    pattern=\w*
    ...    example=my-apigee-org
    ${GCP_PROJECT_ID}=    RW.Core.Import User Variable    GCP_PROJECT_ID
    ...    type=string
    ...    description=GCP Project ID hosting the Apigee runtime.
    ...    pattern=\w*
    ...    example=my-gcp-project
    ${CERT_EXPIRY_WARNING_DAYS}=    RW.Core.Import User Variable    CERT_EXPIRY_WARNING_DAYS
    ...    type=string
    ...    description=Days before certificate expiry at which a keystore alias is flagged.
    ...    pattern=\w*
    ...    default=30
    ${QUOTA_ABUSE_THRESHOLD}=    RW.Core.Import User Variable    QUOTA_ABUSE_THRESHOLD
    ...    type=string
    ...    description=Quota value at/above which an API product is flagged as excessive.
    ...    pattern=\w*
    ...    default=1000000
    ${SECURITY_SCORE_THRESHOLD}=    RW.Core.Import User Variable    SECURITY_SCORE_THRESHOLD
    ...    type=string
    ...    description=Minimum acceptable Apigee security score before the org is flagged.
    ...    pattern=\w*
    ...    default=80
    ${OS_PATH}=    Get Environment Variable    PATH
    Set Suite Variable    ${APIGEE_ORG}    ${APIGEE_ORG}
    Set Suite Variable    ${GCP_PROJECT_ID}    ${GCP_PROJECT_ID}
    Set Suite Variable    ${CERT_EXPIRY_WARNING_DAYS}    ${CERT_EXPIRY_WARNING_DAYS}
    Set Suite Variable    ${QUOTA_ABUSE_THRESHOLD}    ${QUOTA_ABUSE_THRESHOLD}
    Set Suite Variable    ${SECURITY_SCORE_THRESHOLD}    ${SECURITY_SCORE_THRESHOLD}
    Set Suite Variable    ${gcp_credentials}    ${gcp_credentials}
    Set Suite Variable
    ...    ${env}
    ...    {"PATH":"$PATH:${OS_PATH}","APIGEE_ORG":"${APIGEE_ORG}","GCP_PROJECT_ID":"${GCP_PROJECT_ID}","CERT_EXPIRY_WARNING_DAYS":"${CERT_EXPIRY_WARNING_DAYS}","QUOTA_ABUSE_THRESHOLD":"${QUOTA_ABUSE_THRESHOLD}","SECURITY_SCORE_THRESHOLD":"${SECURITY_SCORE_THRESHOLD}"}
    RW.CLI.Run CLI
    ...    cmd=gcloud auth activate-service-account --key-file="./${gcp_credentials.key}" || true
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}


*** Tasks ***
Score Apigee Keystore and TLS Alias Expiry for `${APIGEE_ORG}`
    [Documentation]    Scores keystore/TLS alias expiry. Returns 1 if no expired or soon-to-expire aliases, 0 otherwise.
    [Tags]    gcp    apigee    tls    security    data:config    access:read-only
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check_keystore_tls.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=240
    ${issues_output}=    RW.CLI.Run Cli
    ...    cmd=cat keystore_tls_issues.json | jq length
    ...    env=${env}
    ${tls_score}=    Evaluate    1 if int(${issues_output.stdout}) == 0 else 0
    Set Suite Variable    ${tls_score}
    RW.Core.Push Metric    ${tls_score}    sub_name=tls_keystore_expiry

Score Apigee API Product Quota and Rate Limits for `${APIGEE_ORG}`
    [Documentation]    Scores API product quota/rate limits. Returns 1 if all products have sensible quotas, 0 otherwise.
    [Tags]    gcp    apigee    quota    security    data:config    access:read-only
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check_quota_limits.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=240
    ${issues_output}=    RW.CLI.Run Cli
    ...    cmd=cat quota_limits_issues.json | jq length
    ...    env=${env}
    ${quota_score}=    Evaluate    1 if int(${issues_output.stdout}) == 0 else 0
    Set Suite Variable    ${quota_score}
    RW.Core.Push Metric    ${quota_score}    sub_name=quota_rate_limits

Score Apigee Developer App Access Scope for `${APIGEE_ORG}`
    [Documentation]    Scores developer app access. Returns 1 if no over-broad or risky keys found, 0 otherwise.
    [Tags]    gcp    apigee    access    security    data:config    access:read-only
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check_app_access.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=240
    ${issues_output}=    RW.CLI.Run Cli
    ...    cmd=cat app_access_issues.json | jq length
    ...    env=${env}
    ${app_score}=    Evaluate    1 if int(${issues_output.stdout}) == 0 else 0
    Set Suite Variable    ${app_score}
    RW.Core.Push Metric    ${app_score}    sub_name=app_access_scope

Score Apigee Security Score and Incidents for `${GCP_PROJECT_ID}`
    [Documentation]    Scores Apigee security posture. Returns 1 if the security score is acceptable and no incidents found.
    [Tags]    gcp    apigee    security    monitoring    data:metrics    access:read-only
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check_security_score.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ${issues_output}=    RW.CLI.Run Cli
    ...    cmd=cat security_score_issues.json | jq length
    ...    env=${env}
    ${score_score}=    Evaluate    1 if int(${issues_output.stdout}) == 0 else 0
    Set Suite Variable    ${score_score}
    RW.Core.Push Metric    ${score_score}    sub_name=security_score

Score Apigee Target Server and Virtual Host Configuration for `${APIGEE_ORG}`
    [Documentation]    Scores target server TLS. Returns 1 if all target servers are TLS-enabled, 0 otherwise.
    [Tags]    gcp    apigee    tls    targetserver    security    data:config    access:read-only
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check_target_vhost_config.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ${issues_output}=    RW.CLI.Run Cli
    ...    cmd=cat target_vhost_issues.json | jq length
    ...    env=${env}
    ${target_score}=    Evaluate    1 if int(${issues_output.stdout}) == 0 else 0
    Set Suite Variable    ${target_score}
    RW.Core.Push Metric    ${target_score}    sub_name=target_vhost_config

Generate Aggregate Apigee Security Health Score for `${APIGEE_ORG}`
    [Documentation]    Averages all sub-scores into a final 0-1 security health score for the organization.
    [Tags]    gcp    apigee    security    health    data:metrics    access:read-only
    ${apigee_security_score}=    Evaluate    (${tls_score} + ${quota_score} + ${app_score} + ${score_score} + ${target_score}) / 5
    ${health_score}=    Convert to Number    ${apigee_security_score}    2
    RW.Core.Add to Report    Apigee Security Health Score: ${health_score}
    RW.Core.Push Metric    ${health_score}
