*** Settings ***
Documentation       Monitors the security posture and access configuration of an Apigee organization including TLS keystore alias expiry, API product quota/rate limits, developer app access scope, Apigee security score, and target server configuration.
Metadata            Author    rw-codebundle-agent
Metadata            Display Name    GCP Apigee Security and Configuration Health
Metadata            Supports    GCP,Apigee,Security
Force Tags          GCP    Apigee    Security    Health

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             OperatingSystem
Library             Collections

Suite Setup         Suite Initialization


*** Tasks ***
Check Apigee Keystore and TLS Alias Expiry for `${APIGEE_ORG}`
    [Documentation]    Enumerates keystore and certificate aliases per environment and flags aliases that are expired or will expire within CERT_EXPIRY_WARNING_DAYS days.
    [Tags]    gcp    apigee    tls    security    data:config    access:read-only
    ${tls_result}=    RW.CLI.Run Bash File
    ...    bash_file=check_keystore_tls.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    show_in_rwl_cheatsheet=true
    ...    timeout_seconds=240
    ...    cmd_override=./check_keystore_tls.sh
    ${tls_issues}=    RW.CLI.Run Cli
    ...    cmd=cat keystore_tls_issues.json
    ...    env=${env}
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${tls_issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for keystore/TLS aliases, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=${issue['expected']}
            ...    actual=${issue['actual']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${tls_result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    Apigee Keystore/TLS Alias Analysis:\n${tls_result.stdout}

Check Apigee API Product Quota and Rate Limits for `${APIGEE_ORG}`
    [Documentation]    Reviews API products' quota, rate limit, and approval settings, flagging products with no quota, extreme quota, or auto-approval.
    [Tags]    gcp    apigee    quota    security    data:config    access:read-only
    ${quota_result}=    RW.CLI.Run Bash File
    ...    bash_file=check_quota_limits.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    show_in_rwl_cheatsheet=true
    ...    timeout_seconds=240
    ...    cmd_override=./check_quota_limits.sh
    ${quota_issues}=    RW.CLI.Run Cli
    ...    cmd=cat quota_limits_issues.json
    ...    env=${env}
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${quota_issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for quota limits, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=${issue['expected']}
            ...    actual=${issue['actual']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${quota_result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    Apigee API Product Quota Analysis:\n${quota_result.stdout}

Check Apigee Developer App Access Scope for `${APIGEE_ORG}`
    [Documentation]    Reviews developer apps and consumer keys for over-broad scopes and inactive keys that pose an access-control risk.
    [Tags]    gcp    apigee    access    security    data:config    access:read-only
    ${app_result}=    RW.CLI.Run Bash File
    ...    bash_file=check_app_access.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    show_in_rwl_cheatsheet=true
    ...    timeout_seconds=240
    ...    cmd_override=./check_app_access.sh
    ${app_issues}=    RW.CLI.Run Cli
    ...    cmd=cat app_access_issues.json
    ...    env=${env}
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${app_issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for app access, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=${issue['expected']}
            ...    actual=${issue['actual']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${app_result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    Apigee Developer App Access Analysis:\n${app_result.stdout}

Check Apigee Security Score and Incidents for `${GCP_PROJECT_ID}`
    [Documentation]    Queries Apigee security metrics to flag organizations with a low security score or a high number of detected incidents.
    [Tags]    gcp    apigee    security    monitoring    data:metrics    access:read-only
    ${score_result}=    RW.CLI.Run Bash File
    ...    bash_file=check_security_score.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    show_in_rwl_cheatsheet=true
    ...    timeout_seconds=180
    ...    cmd_override=./check_security_score.sh
    ${score_issues}=    RW.CLI.Run Cli
    ...    cmd=cat security_score_issues.json
    ...    env=${env}
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${score_issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for security score, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=${issue['expected']}
            ...    actual=${issue['actual']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${score_result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    Apigee Security Score Analysis:\n${score_result.stdout}

Check Apigee Target Server and Virtual Host Configuration for `${APIGEE_ORG}`
    [Documentation]    Reviews target servers for missing or incorrect TLS configuration, flagging plaintext or misconfigured backends.
    [Tags]    gcp    apigee    tls    targetserver    security    data:config    access:read-only
    ${target_result}=    RW.CLI.Run Bash File
    ...    bash_file=check_target_vhost_config.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    show_in_rwl_cheatsheet=true
    ...    timeout_seconds=180
    ...    cmd_override=./check_target_vhost_config.sh
    ${target_issues}=    RW.CLI.Run Cli
    ...    cmd=cat target_vhost_issues.json
    ...    env=${env}
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${target_issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for target/vhost config, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=${issue['expected']}
            ...    actual=${issue['actual']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${target_result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    Apigee Target Server / Virtual Host Analysis:\n${target_result.stdout}

Generate Apigee Security Summary for `${APIGEE_ORG}`
    [Documentation]    Produces a consolidated security summary aggregating keystore, quota, app access, security score, and target/vhost findings.
    [Tags]    gcp    apigee    security    summary    data:config    access:read-only
    ${summary_result}=    RW.CLI.Run Bash File
    ...    bash_file=generate_security_summary.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    show_in_rwl_cheatsheet=true
    ...    timeout_seconds=120
    ...    cmd_override=./generate_security_summary.sh
    ${summary_output}=    RW.CLI.Run Cli
    ...    cmd=cat security_summary.json
    ...    env=${env}
    RW.Core.Add Pre To Report    Apigee Security Summary:\n${summary_output.stdout}
    RW.Core.Add Pre To Report    Commands Used:\n${summary_result.cmd}


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
    ...    description=GCP Project ID hosting the Apigee runtime (used for security metric queries).
    ...    pattern=\w*
    ...    example=my-gcp-project
    ${CERT_EXPIRY_WARNING_DAYS}=    RW.Core.Import User Variable    CERT_EXPIRY_WARNING_DAYS
    ...    type=string
    ...    description=Days before certificate expiry at which a keystore alias is flagged.
    ...    pattern=\w*
    ...    default=30
    ${QUOTA_ABUSE_THRESHOLD}=    RW.Core.Import User Variable    QUOTA_ABUSE_THRESHOLD
    ...    type=string
    ...    description=Quota value (requests/time) at or above which an API product is flagged as excessive.
    ...    pattern=\w*
    ...    default=1000000
    ${SECURITY_SCORE_THRESHOLD}=    RW.Core.Import User Variable    SECURITY_SCORE_THRESHOLD
    ...    type=string
    ...    description=Minimum acceptable Apigee security score (0-100) before the org is flagged.
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
