*** Settings ***
Documentation       Monitors the data-protection and configuration governance posture of GCP Cloud Spanner: backup existence/recency, backup expiration, point-in-time-recovery retention, deletion protection, IAM access, and encryption (CMEK).
Metadata            Author    rw-codebundle-agent
Metadata            Display Name    GCP Cloud Spanner Backup & Data Protection
Metadata            Supports    GCP,Spanner
Force Tags          GCP    Spanner    Backup    DataProtection

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             OperatingSystem
Library             Collections

Suite Setup         Suite Initialization


*** Tasks ***
Check Cloud Spanner Backup Existence and Recency for `${GCP_PROJECT_ID}`
    [Documentation]    Lists backups per database and flags databases with no backup or whose most recent backup is older than the recency threshold.
    [Tags]    gcp    spanner    backup    recency    data:config    access:read-only
    ${recency_result}=    RW.CLI.Run Bash File
    ...    bash_file=check_backup_recency.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    show_in_rwl_cheatsheet=true
    ...    timeout_seconds=180
    ...    cmd_override=./check_backup_recency.sh
    ${recency_issues}=    RW.CLI.Run Cli
    ...    cmd=cat backup_recency_issues.json
    ...    env=${env}
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${recency_issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for backup recency, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=${issue['expected']}
            ...    actual=${issue['actual']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${recency_result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    Cloud Spanner Backup Recency Analysis:\n${recency_result.stdout}

Check Cloud Spanner Backup Expiration for `${GCP_PROJECT_ID}`
    [Documentation]    Inspects backup expire_time and flags backups already expired or expiring within the warning window, leaving retention gaps.
    [Tags]    gcp    spanner    backup    expiration    data:config    access:read-only
    ${expiration_result}=    RW.CLI.Run Bash File
    ...    bash_file=check_backup_expiration.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    show_in_rwl_cheatsheet=true
    ...    timeout_seconds=180
    ...    cmd_override=./check_backup_expiration.sh
    ${expiration_issues}=    RW.CLI.Run Cli
    ...    cmd=cat backup_expiration_issues.json
    ...    env=${env}
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${expiration_issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for backup expiration, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=${issue['expected']}
            ...    actual=${issue['actual']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${expiration_result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    Cloud Spanner Backup Expiration Analysis:\n${expiration_result.stdout}

Check Cloud Spanner Point-in-Time Recovery Configuration for `${GCP_PROJECT_ID}`
    [Documentation]    Reads each database's version_retention_period and flags databases below the recommended PITR window.
    [Tags]    gcp    spanner    database    pitr    data:config    access:read-only
    ${pitr_result}=    RW.CLI.Run Bash File
    ...    bash_file=check_pitr_config.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    show_in_rwl_cheatsheet=true
    ...    timeout_seconds=180
    ...    cmd_override=./check_pitr_config.sh
    ${pitr_issues}=    RW.CLI.Run Cli
    ...    cmd=cat pitr_config_issues.json
    ...    env=${env}
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${pitr_issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for PITR configuration, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=${issue['expected']}
            ...    actual=${issue['actual']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${pitr_result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    Cloud Spanner PITR Configuration Analysis:\n${pitr_result.stdout}

Check Cloud Spanner Deletion Protection for `${GCP_PROJECT_ID}`
    [Documentation]    Flags instances and databases with deletion protection disabled, which risks accidental data loss.
    [Tags]    gcp    spanner    instance    database    deletion-protection    data:config    access:read-only
    ${deletion_result}=    RW.CLI.Run Bash File
    ...    bash_file=check_deletion_protection.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    show_in_rwl_cheatsheet=true
    ...    timeout_seconds=180
    ...    cmd_override=./check_deletion_protection.sh
    ${deletion_issues}=    RW.CLI.Run Cli
    ...    cmd=cat deletion_protection_issues.json
    ...    env=${env}
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${deletion_issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for deletion protection, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=${issue['expected']}
            ...    actual=${issue['actual']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${deletion_result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    Cloud Spanner Deletion Protection Analysis:\n${deletion_result.stdout}

Check Cloud Spanner IAM Access Configuration for `${GCP_PROJECT_ID}`
    [Documentation]    Reviews IAM policy on instances/databases for public bindings (allUsers, allAuthenticatedUsers) and overly-permissive primitive roles.
    [Tags]    gcp    spanner    instance    database    iam    data:config    access:read-only
    ${iam_result}=    RW.CLI.Run Bash File
    ...    bash_file=check_iam_access.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    show_in_rwl_cheatsheet=true
    ...    timeout_seconds=180
    ...    cmd_override=./check_iam_access.sh
    ${iam_issues}=    RW.CLI.Run Cli
    ...    cmd=cat iam_access_issues.json
    ...    env=${env}
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${iam_issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for IAM access, defaulting to empty list.    WARN
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
    RW.Core.Add Pre To Report    Cloud Spanner IAM Access Analysis:\n${iam_result.stdout}

Check Cloud Spanner Encryption Configuration for `${GCP_PROJECT_ID}`
    [Documentation]    Reports whether each database uses Google-managed or customer-managed encryption (CMEK) and flags deviations from the required encryption policy.
    [Tags]    gcp    spanner    database    encryption    cmek    data:config    access:read-only
    ${encryption_result}=    RW.CLI.Run Bash File
    ...    bash_file=check_encryption_config.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    show_in_rwl_cheatsheet=true
    ...    timeout_seconds=180
    ...    cmd_override=./check_encryption_config.sh
    ${encryption_issues}=    RW.CLI.Run Cli
    ...    cmd=cat encryption_config_issues.json
    ...    env=${env}
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${encryption_issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for encryption configuration, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=${issue['expected']}
            ...    actual=${issue['actual']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${encryption_result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    Cloud Spanner Encryption Configuration Analysis:\n${encryption_result.stdout}

Generate Cloud Spanner Data Protection Summary for `${GCP_PROJECT_ID}`
    [Documentation]    Produces a consolidated per-database JSON summary of backup recency, PITR window, deletion protection, IAM exposure, and encryption, with an overall verdict.
    [Tags]    gcp    spanner    database    summary    data:config    access:read-only
    ${summary_result}=    RW.CLI.Run Bash File
    ...    bash_file=generate_protection_summary.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    show_in_rwl_cheatsheet=true
    ...    timeout_seconds=180
    ...    cmd_override=./generate_protection_summary.sh
    ${summary_issues}=    RW.CLI.Run Cli
    ...    cmd=cat protection_summary_issues.json
    ...    env=${env}
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${summary_issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for protection summary, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=${issue['expected']}
            ...    actual=${issue['actual']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${summary_result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    ${summary_output}=    RW.CLI.Run Cli
    ...    cmd=cat protection_summary.json
    ...    env=${env}
    RW.Core.Add Pre To Report    Cloud Spanner Data Protection Summary:\n${summary_output.stdout}
    RW.Core.Add Pre To Report    Commands Used:\n${summary_result.cmd}


*** Keywords ***
Suite Initialization
    ${gcp_credentials}=    RW.Core.Import Secret    gcp_credentials
    ...    type=string
    ...    description=GCP service account JSON key used to authenticate with GCP APIs. Requires Spanner Viewer and Spanner Backup Viewer roles.
    ...    pattern=\w*
    ...    example={"type": "service_account","project_id":"myproject-ID"}
    ${GCP_PROJECT_ID}=    RW.Core.Import User Variable    GCP_PROJECT_ID
    ...    type=string
    ...    description=GCP Project ID containing the Cloud Spanner instances.
    ...    pattern=\w*
    ...    example=my-gcp-project
    ${BACKUP_RECENCY_THRESHOLD_HOURS}=    RW.Core.Import User Variable    BACKUP_RECENCY_THRESHOLD_HOURS
    ...    type=string
    ...    description=Max age (hours) of the most recent backup before an issue is raised.
    ...    pattern=\w*
    ...    default=24
    ${BACKUP_EXPIRY_WARNING_DAYS}=    RW.Core.Import User Variable    BACKUP_EXPIRY_WARNING_DAYS
    ...    type=string
    ...    description=Warn if a backup expires within this many days.
    ...    pattern=\w*
    ...    default=3
    ${PITR_MINIMUM_DAYS}=    RW.Core.Import User Variable    PITR_MINIMUM_DAYS
    ...    type=string
    ...    description=Minimum recommended point-in-time-recovery retention (days).
    ...    pattern=\w*
    ...    default=1
    ${REQUIRE_CMEK}=    RW.Core.Import User Variable    REQUIRE_CMEK
    ...    type=string
    ...    description=If 'true', flag databases not using customer-managed encryption.
    ...    pattern=\w*
    ...    default=false
    ...    enum=[true,false]
    ${OS_PATH}=    Get Environment Variable    PATH
    Set Suite Variable    ${GCP_PROJECT_ID}    ${GCP_PROJECT_ID}
    Set Suite Variable    ${BACKUP_RECENCY_THRESHOLD_HOURS}    ${BACKUP_RECENCY_THRESHOLD_HOURS}
    Set Suite Variable    ${BACKUP_EXPIRY_WARNING_DAYS}    ${BACKUP_EXPIRY_WARNING_DAYS}
    Set Suite Variable    ${PITR_MINIMUM_DAYS}    ${PITR_MINIMUM_DAYS}
    Set Suite Variable    ${REQUIRE_CMEK}    ${REQUIRE_CMEK}
    Set Suite Variable    ${gcp_credentials}    ${gcp_credentials}
    Set Suite Variable
    ...    ${env}
    ...    {"PATH":"$PATH:${OS_PATH}","GCP_PROJECT_ID":"${GCP_PROJECT_ID}","BACKUP_RECENCY_THRESHOLD_HOURS":"${BACKUP_RECENCY_THRESHOLD_HOURS}","BACKUP_EXPIRY_WARNING_DAYS":"${BACKUP_EXPIRY_WARNING_DAYS}","PITR_MINIMUM_DAYS":"${PITR_MINIMUM_DAYS}","REQUIRE_CMEK":"${REQUIRE_CMEK}"}
    RW.CLI.Run CLI
    ...    cmd=gcloud auth activate-service-account --key-file="./${gcp_credentials.key}" || true
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
