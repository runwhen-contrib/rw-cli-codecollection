*** Settings ***
Documentation       Measures the configuration-health of a GCP project by scoring PERMISSION_DENIED activity, IAM policy changes, org policy constraint violations, and audit log configuration. Produces a value between 0 (completely failing) and 1 (fully passing).
Metadata            Author    rw-codebundle-agent
Metadata            Display Name    GCP Project Configuration Audit
Metadata            Supports    GCP,Project,IAM,Logging
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
    ...    description=GCP service account JSON key used to authenticate with GCP APIs.
    ...    pattern=\w*
    ...    example={"type": "service_account","project_id":"myproject-ID"}
    ${GCP_PROJECT_ID}=    RW.Core.Import User Variable    GCP_PROJECT_ID
    ...    type=string
    ...    description=GCP project ID to audit for configuration risks.
    ...    pattern=\w*
    ...    example=my-gcp-project
    ${LOOKBACK_WINDOW}=    RW.Core.Import User Variable    LOOKBACK_WINDOW
    ...    type=string
    ...    description=ISO-8601 duration defining how far back to analyze Cloud Audit Logs.
    ...    pattern=.*
    ...    default=P7D
    ${PERMISSION_DENIED_THRESHOLD}=    RW.Core.Import User Variable    PERMISSION_DENIED_THRESHOLD
    ...    type=string
    ...    description=Minimum number of distinct PERMISSION_DENIED events before an issue of severity 3 is raised.
    ...    pattern=\w*
    ...    default=10
    ${ORG_ID}=    RW.Core.Import User Variable    ORG_ID
    ...    type=string
    ...    description=Optional parent organization ID used to evaluate inherited org policy constraints.
    ...    pattern=.*
    ...    default=
    ${OS_PATH}=    Get Environment Variable    PATH
    Set Suite Variable    ${GCP_PROJECT_ID}    ${GCP_PROJECT_ID}
    Set Suite Variable    ${LOOKBACK_WINDOW}    ${LOOKBACK_WINDOW}
    Set Suite Variable    ${PERMISSION_DENIED_THRESHOLD}    ${PERMISSION_DENIED_THRESHOLD}
    Set Suite Variable    ${ORG_ID}    ${ORG_ID}
    Set Suite Variable    ${gcp_credentials}    ${gcp_credentials}
    Set Suite Variable
    ...    ${env}
    ...    {"PATH":"$PATH:${OS_PATH}","GCP_PROJECT_ID":"${GCP_PROJECT_ID}","LOOKBACK_WINDOW":"${LOOKBACK_WINDOW}","PERMISSION_DENIED_THRESHOLD":"${PERMISSION_DENIED_THRESHOLD}","ORG_ID":"${ORG_ID}"}
    RW.CLI.Run CLI
    ...    cmd=gcloud auth activate-service-account --key-file="./${gcp_credentials.key}" || true
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}


*** Tasks ***
Score PERMISSION_DENIED Activity for `${GCP_PROJECT_ID}`
    [Documentation]    Scores high-volume PERMISSION_DENIED activity. Returns 1 if no elevated denied events, 0 otherwise.
    [Tags]    gcp    logging    security    data:logs    access:read-only
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=analyze_permission_denied.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ${issues_output}=    RW.CLI.Run Cli
    ...    cmd=cat permission_denied_issues.json | jq '[.[] | select(.severity >= 2)] | length'
    ...    env=${env}
    ${score}=    Evaluate    1 if int(${issues_output.stdout}) == 0 else 0
    Set Suite Variable    ${permission_denied_score}
    RW.Core.Push Metric    ${permission_denied_score}    sub_name=permission_denied

Score IAM Policy Changes for `${GCP_PROJECT_ID}`
    [Documentation]    Scores IAM policy changes. Returns 1 if no unexpected privileged IAM changes, 0 otherwise.
    [Tags]    gcp    iam    security    data:logs-config    access:read-only
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=detect_iam_policy_changes.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ${issues_output}=    RW.CLI.Run Cli
    ...    cmd=cat iam_policy_changes_issues.json | jq '[.[] | select(.severity >= 2)] | length'
    ...    env=${env}
    ${score}=    Evaluate    1 if int(${issues_output.stdout}) == 0 else 0
    Set Suite Variable    ${iam_change_score}
    RW.Core.Push Metric    ${iam_change_score}    sub_name=iam_policy_changes

Score Org Policy Constraint Compliance for `${GCP_PROJECT_ID}`
    [Documentation]    Scores org policy compliance. Returns 1 if no constraint violations, 0 otherwise.
    [Tags]    gcp    orgpolicy    security    data:config    access:read-only
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=analyze_org_policy_violations.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ${issues_output}=    RW.CLI.Run Cli
    ...    cmd=cat org_policy_violation_issues.json | jq '[.[] | select(.severity >= 2)] | length'
    ...    env=${env}
    ${score}=    Evaluate    1 if int(${issues_output.stdout}) == 0 else 0
    Set Suite Variable    ${org_policy_score}
    RW.Core.Push Metric    ${org_policy_score}    sub_name=org_policy

Score Audit Log Configuration for `${GCP_PROJECT_ID}`
    [Documentation]    Scores audit log configuration. Returns 1 if audit logging is properly configured, 0 otherwise.
    [Tags]    gcp    logging    auditing    data:config    access:read-only
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check_audit_log_config.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ${issues_output}=    RW.CLI.Run Cli
    ...    cmd=cat audit_log_config_issues.json | jq '[.[] | select(.severity >= 2)] | length'
    ...    env=${env}
    ${score}=    Evaluate    1 if int(${issues_output.stdout}) == 0 else 0
    Set Suite Variable    ${audit_log_score}
    RW.Core.Push Metric    ${audit_log_score}    sub_name=audit_log_config

Generate Aggregate GCP Project Configuration Audit Score for `${GCP_PROJECT_ID}`
    [Documentation]    Averages all sub-scores into a final 0-1 configuration health score for the project.
    [Tags]    gcp    project    health    data:metrics    access:read-only
    ${audit_health_score}=    Evaluate    (${permission_denied_score} + ${iam_change_score} + ${org_policy_score} + ${audit_log_score}) / 4
    ${health_score}=    Convert to Number    ${audit_health_score}    2
    RW.Core.Add to Report    GCP Project Configuration Audit Health Score: ${health_score}
    RW.Core.Push Metric    ${health_score}
