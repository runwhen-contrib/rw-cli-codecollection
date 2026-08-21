*** Settings ***
Documentation       Audits a GCP project's configuration for security and operational risks by analyzing Cloud Audit Logs for PERMISSION_DENIED events, detecting IAM policy changes over a lookback window, and surfacing org policy constraint violations.
Metadata            Author    rw-codebundle-agent
Metadata            Display Name    GCP Project Configuration Audit
Metadata            Supports    GCP,Project,IAM,Logging
Force Tags          GCP    Project    IAM    Logging    Audit

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             OperatingSystem
Library             Collections

Suite Setup         Suite Initialization


*** Tasks ***
Analyze Cloud Audit Logs for PERMISSION_DENIED Events in Project `${GCP_PROJECT_ID}`
    [Documentation]    Queries Cloud Logging admin activity logs for PERMISSION_DENIED events over the lookback window and flags unusually high volumes or repeated denied actions.
    [Tags]    gcp    logging    security    data:logs    access:read-only
    ${pd_result}=    RW.CLI.Run Bash File
    ...    bash_file=analyze_permission_denied.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    show_in_rwl_cheatsheet=true
    ...    timeout_seconds=180
    ...    cmd_override=./analyze_permission_denied.sh
    ${pd_issues}=    RW.CLI.Run Cli
    ...    cmd=cat permission_denied_issues.json
    ...    env=${env}
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${pd_issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for permission denied analysis, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=${issue['expected']}
            ...    actual=${issue['actual']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${pd_result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    PERMISSION_DENIED Analysis:\n${pd_result.stdout}

Detect IAM Policy Changes in Project `${GCP_PROJECT_ID}` Over `${LOOKBACK_WINDOW}`
    [Documentation]    Inspects Cloud Audit Logs for SetIamPolicy events and reports who granted or revoked roles, highlighting privileged-role changes for review.
    [Tags]    gcp    iam    security    data:logs-config    access:read-only
    ${iam_result}=    RW.CLI.Run Bash File
    ...    bash_file=detect_iam_policy_changes.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    show_in_rwl_cheatsheet=true
    ...    timeout_seconds=180
    ...    cmd_override=./detect_iam_policy_changes.sh
    ${iam_issues}=    RW.CLI.Run Cli
    ...    cmd=cat iam_policy_changes_issues.json
    ...    env=${env}
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${iam_issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for IAM policy changes, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=${issue['expected']}
            ...    actual=${issue['actual']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${iam_result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    IAM Policy Change Analysis:\n${iam_result.stdout}

Analyze Org Policy Constraint Violations in Project `${GCP_PROJECT_ID}`
    [Documentation]    Enumerates enforced Organization Policy constraints for the project and reports violations such as public bucket access or disabled service usage.
    [Tags]    gcp    orgpolicy    security    data:config    access:read-only
    ${org_result}=    RW.CLI.Run Bash File
    ...    bash_file=analyze_org_policy_violations.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    show_in_rwl_cheatsheet=true
    ...    timeout_seconds=180
    ...    cmd_override=./analyze_org_policy_violations.sh
    ${org_issues}=    RW.CLI.Run Cli
    ...    cmd=cat org_policy_violation_issues.json
    ...    env=${env}
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${org_issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for org policy analysis, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=${issue['expected']}
            ...    actual=${issue['actual']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${org_result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    Org Policy Constraint Analysis:\n${org_result.stdout}

Verify Cloud Audit Log Configuration for Project `${GCP_PROJECT_ID}`
    [Documentation]    Checks that admin activity, data access, and policy denied audit logging modes are enabled and that a log sink or export exists so log-based audit tasks are meaningful.
    [Tags]    gcp    logging    auditing    data:config    access:read-only
    ${audit_result}=    RW.CLI.Run Bash File
    ...    bash_file=check_audit_log_config.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    show_in_rwl_cheatsheet=true
    ...    timeout_seconds=180
    ...    cmd_override=./check_audit_log_config.sh
    ${audit_issues}=    RW.CLI.Run Cli
    ...    cmd=cat audit_log_config_issues.json
    ...    env=${env}
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${audit_issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for audit log config, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=${issue['expected']}
            ...    actual=${issue['actual']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${audit_result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    Audit Log Configuration Analysis:\n${audit_result.stdout}

Generate Project Configuration Audit Summary Report for `${GCP_PROJECT_ID}`
    [Documentation]    Aggregates findings from the permission-denied, IAM-change, org-policy, and audit-log tasks into a single consolidated risk summary for the project.
    [Tags]    gcp    report    summary    data:report    access:read-only
    ${summary_result}=    RW.CLI.Run Bash File
    ...    bash_file=generate_audit_summary.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    show_in_rwl_cheatsheet=true
    ...    timeout_seconds=180
    ...    cmd_override=./generate_audit_summary.sh
    ${summary_output}=    RW.CLI.Run Cli
    ...    cmd=cat audit_summary.json
    ...    env=${env}
    RW.Core.Add Pre To Report    Consolidated Project Configuration Audit Summary:\n${summary_output.stdout}
    RW.Core.Add Pre To Report    Commands Used:\n${summary_result.cmd}


*** Keywords ***
Suite Initialization
    ${gcp_credentials}=    RW.Core.Import Secret    gcp_credentials
    ...    type=string
    ...    description=GCP service account JSON key used to authenticate with Cloud Logging, IAM, and Org Policy APIs.
    ...    pattern=\w*
    ...    example={"type": "service_account","project_id":"myproject-ID"}
    ${GCP_PROJECT_ID}=    RW.Core.Import User Variable    GCP_PROJECT_ID
    ...    type=string
    ...    description=GCP project ID to audit for configuration risks.
    ...    pattern=\w*
    ...    example=my-gcp-project
    ${LOOKBACK_WINDOW}=    RW.Core.Import User Variable    LOOKBACK_WINDOW
    ...    type=string
    ...    description=ISO-8601 duration defining how far back to analyze Cloud Audit Logs (e.g. P7D, PT6H, P30D).
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
