*** Settings ***
Documentation       Monitors GCP IAM service account health including privileged role assignments, key rotation, key count, disabled service accounts in use, and IAM policy drift.
Metadata            Author    rw-codebundle-agent
Metadata            Display Name    GCP IAM Service Account Health
Metadata            Supports    GCP,IAM,ServiceAccount,Security
Force Tags          GCP    IAM    ServiceAccount    Security

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             OperatingSystem
Library             DateTime
Library             Collections

Suite Setup         Suite Initialization


*** Tasks ***
Check Service Account Privileged Role Assignments for `${GCP_PROJECT_ID}`
    [Documentation]    Lists service accounts granted owner, editor, or other high-privilege roles at the project or service-account level and flags them for review.
    [Tags]    gcp    iam    serviceaccount    security    data:config    access:read-only
    ${priv_result}=    RW.CLI.Run Bash File
    ...    bash_file=check_privileged_roles.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    show_in_rwl_cheatsheet=true
    ...    timeout_seconds=180
    ...    cmd_override=./check_privileged_roles.sh
    ${priv_issues}=    RW.CLI.Run Cli
    ...    cmd=cat privileged_roles_issues.json
    ...    env=${env}
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${priv_issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for privileged role assignments, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=${issue['expected']}
            ...    actual=${issue['actual']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${priv_result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    Service Account Privileged Role Analysis:\n${priv_result.stdout}

Check Service Account Key Rotation for `${GCP_PROJECT_ID}`
    [Documentation]    Detects service account keys older than the configured rotation threshold and warns when rotation is overdue.
    [Tags]    gcp    iam    serviceaccount    security    data:config    access:read-only
    ${rot_result}=    RW.CLI.Run Bash File
    ...    bash_file=check_key_rotation.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    show_in_rwl_cheatsheet=true
    ...    timeout_seconds=180
    ...    cmd_override=./check_key_rotation.sh
    ${rot_issues}=    RW.CLI.Run Cli
    ...    cmd=cat key_rotation_issues.json
    ...    env=${env}
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${rot_issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for key rotation, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=${issue['expected']}
            ...    actual=${issue['actual']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${rot_result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    Service Account Key Rotation Analysis:\n${rot_result.stdout}

Identify Service Accounts with Excessive Keys for `${GCP_PROJECT_ID}`
    [Documentation]    Flags service accounts holding more than the allowed number of active keys, which broadens the attack surface.
    [Tags]    gcp    iam    serviceaccount    security    data:config    access:read-only
    ${count_result}=    RW.CLI.Run Bash File
    ...    bash_file=check_key_count.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    show_in_rwl_cheatsheet=true
    ...    timeout_seconds=180
    ...    cmd_override=./check_key_count.sh
    ${count_issues}=    RW.CLI.Run Cli
    ...    cmd=cat key_count_issues.json
    ...    env=${env}
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${count_issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for key count, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=${issue['expected']}
            ...    actual=${issue['actual']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${count_result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    Service Account Key Count Analysis:\n${count_result.stdout}

Identify Disabled Service Accounts in Use for `${GCP_PROJECT_ID}`
    [Documentation]    Finds disabled service accounts that are still referenced in IAM policy bindings, which can indicate drift.
    [Tags]    gcp    iam    serviceaccount    security    data:config    access:read-only
    ${disc_result}=    RW.CLI.Run Bash File
    ...    bash_file=check_disabled_service_accounts.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    show_in_rwl_cheatsheet=true
    ...    timeout_seconds=180
    ...    cmd_override=./check_disabled_service_accounts.sh
    ${disc_issues}=    RW.CLI.Run Cli
    ...    cmd=cat disabled_sa_issues.json
    ...    env=${env}
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${disc_issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for disabled service accounts, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=${issue['expected']}
            ...    actual=${issue['actual']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${disc_result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    Disabled Service Account Analysis:\n${disc_result.stdout}

Analyze Service Account IAM Policy for Project `${GCP_PROJECT_ID}`
    [Documentation]    Summarizes all service-account-level IAM role bindings in the project for a quick health overview and drift detection.
    [Tags]    gcp    iam    serviceaccount    security    data:config    access:read-only
    ${pol_result}=    RW.CLI.Run Bash File
    ...    bash_file=analyze_service_account_policy.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    show_in_rwl_cheatsheet=true
    ...    timeout_seconds=180
    ...    cmd_override=./analyze_service_account_policy.sh
    ${pol_issues}=    RW.CLI.Run Cli
    ...    cmd=cat policy_analysis_issues.json
    ...    env=${env}
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${pol_issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for policy analysis, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=${issue['expected']}
            ...    actual=${issue['actual']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${pol_result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    Service Account IAM Policy Analysis:\n${pol_result.stdout}


*** Keywords ***
Suite Initialization
    ${gcp_credentials}=    RW.Core.Import Secret    gcp_credentials
    ...    type=string
    ...    description=GCP service account JSON key used to authenticate with GCP APIs.
    ...    pattern=\w*
    ...    example={"type": "service_account","project_id":"myproject-ID"}
    ${GCP_PROJECT_ID}=    RW.Core.Import User Variable    GCP_PROJECT_ID
    ...    type=string
    ...    description=GCP Project ID that houses the service accounts to inspect.
    ...    pattern=\w*
    ...    example=my-gcp-project
    ${SERVICE_ACCOUNT}=    RW.Core.Import User Variable    SERVICE_ACCOUNT
    ...    type=string
    ...    description=Optional email of a single service account to scope checks to. Empty means all service accounts in the project.
    ...    pattern=\w*
    ...    default=
    ${KEY_ROTATION_DAYS}=    RW.Core.Import User Variable    KEY_ROTATION_DAYS
    ...    type=string
    ...    description=Maximum allowed age of a service account key in days before rotation is flagged.
    ...    pattern=^\d+$
    ...    default=90
    ${MAX_KEYS_PER_SA}=    RW.Core.Import User Variable    MAX_KEYS_PER_SA
    ...    type=string
    ...    description=Maximum allowed number of active keys per service account before it is flagged.
    ...    pattern=^\d+$
    ...    default=5
    ${PRIVILEGED_ROLES}=    RW.Core.Import User Variable    PRIVILEGED_ROLES
    ...    type=string
    ...    description=Comma-separated list of roles considered high-privilege and worth flagging.
    ...    pattern=\w*
    ...    default=roles/owner,roles/editor
    ${OS_PATH}=    Get Environment Variable    PATH
    Set Suite Variable    ${GCP_PROJECT_ID}    ${GCP_PROJECT_ID}
    Set Suite Variable    ${SERVICE_ACCOUNT}    ${SERVICE_ACCOUNT}
    Set Suite Variable    ${KEY_ROTATION_DAYS}    ${KEY_ROTATION_DAYS}
    Set Suite Variable    ${MAX_KEYS_PER_SA}    ${MAX_KEYS_PER_SA}
    Set Suite Variable    ${PRIVILEGED_ROLES}    ${PRIVILEGED_ROLES}
    Set Suite Variable    ${gcp_credentials}    ${gcp_credentials}
    Set Suite Variable
    ...    ${env}
    ...    {"PATH":"$PATH:${OS_PATH}","GCP_PROJECT_ID":"${GCP_PROJECT_ID}","SERVICE_ACCOUNT":"${SERVICE_ACCOUNT}","KEY_ROTATION_DAYS":"${KEY_ROTATION_DAYS}","MAX_KEYS_PER_SA":"${MAX_KEYS_PER_SA}","PRIVILEGED_ROLES":"${PRIVILEGED_ROLES}"}
    RW.CLI.Run CLI
    ...    cmd=gcloud auth activate-service-account --key-file="./${gcp_credentials.key}" || true
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
