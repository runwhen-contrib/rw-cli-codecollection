*** Settings ***
Documentation       Monitors Google Cloud Database Migration Service migration jobs for failed or stuck states, operation failures, and CDC replication lag using gcloud and Cloud Monitoring.
Metadata            Author    rw-codebundle-agent
Metadata            Display Name    GCP Database Migration Service (DMS) Health
Metadata            Supports    GCP DMS Database Migration Replication CDC

Library             BuiltIn
Library             String
Library             RW.Core
Library             RW.CLI
Library             RW.platform

Force Tags          GCP    DMS    Migration    Health

Suite Setup         Suite Initialization


*** Tasks ***
List DMS Migration Jobs and Flag Unhealthy States for `${GCP_PROJECT_ID}`
    [Documentation]    Lists migration jobs in the DMS region and raises issues for failed, paused, cancelled, stuck transitional states, or RUNNING jobs not yet in CDC beyond the stuck threshold.
    [Tags]    GCP    DMS    migration-jobs    access:read-only    data:metrics

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=list-migration-jobs.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=240
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./list-migration-jobs.sh

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat list_migration_jobs_issues.json
    ...    env=${env}
    ...    include_in_history=false

    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for migration job list issues; defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END

    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=DMS migration jobs should not be failed, stuck indefinitely, or blocked before CDC when continuous replication is required.
            ...    actual=One or more migration jobs in `${GCP_DMS_LOCATION}` need attention.
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END

    RW.Core.Add Pre To Report    DMS migration job analysis (region `${GCP_DMS_LOCATION}`):
    RW.Core.Add Pre To Report    ${result.stdout}

List Recent DMS Operations and Flag Failures for `${GCP_PROJECT_ID}`
    [Documentation]    Lists recent DMS operations in the region and surfaces operation errors and long-running incomplete operations.
    [Tags]    GCP    DMS    operations    access:read-only    data:metrics

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=list-dms-operations.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=240
    ...    show_in_rwl_cheatsheet=false
    ...    cmd_override=./list-dms-operations.sh

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat list_dms_operations_issues.json
    ...    env=${env}
    ...    include_in_history=false

    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for DMS operations issues; defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END

    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=DMS operations should complete without errors and should not remain pending indefinitely.
            ...    actual=An operation in `${GCP_DMS_LOCATION}` failed or appears stuck.
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END

    RW.Core.Add Pre To Report    DMS operations listing:
    RW.Core.Add Pre To Report    ${result.stdout}

Report DMS Replication Lag from Cloud Monitoring for `${GCP_PROJECT_ID}`
    [Documentation]    Reads Cloud Monitoring metrics for CDC migration jobs and flags replication lag above configured thresholds (samples may trail by up to ~180s).
    [Tags]    GCP    DMS    monitoring    CDC    access:read-only    data:metrics

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=fetch-dms-replication-lag-metrics.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=240
    ...    show_in_rwl_cheatsheet=false
    ...    cmd_override=./fetch-dms-replication-lag-metrics.sh

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat fetch_dms_replication_lag_issues.json
    ...    env=${env}
    ...    include_in_history=false

    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for replication lag issues; defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END

    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=CDC replication lag should stay below configured thresholds before cutover.
            ...    actual=Replication lag metrics indicate the destination is too far behind the source for at least one job.
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END

    RW.Core.Add Pre To Report    DMS replication lag (Monitoring):
    RW.Core.Add Pre To Report    ${result.stdout}

Summarize DMS Migration Job Details for Flagged Jobs in `${GCP_PROJECT_ID}`
    [Documentation]    Describes migration jobs selected via DMS_JOB_NAMES or jobs flagged by earlier tasks to capture phase, errors, and configuration context.
    [Tags]    GCP    DMS    describe    access:read-only    data:metrics

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=describe-migration-jobs.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=240
    ...    show_in_rwl_cheatsheet=false
    ...    cmd_override=./describe-migration-jobs.sh

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat describe_migration_jobs_issues.json
    ...    env=${env}
    ...    include_in_history=false

    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for describe issues; defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END

    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=DMS migration job describe output should not contain unresolved error payloads for healthy jobs.
            ...    actual=Describe output shows error details for a migration job in `${GCP_DMS_LOCATION}`.
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END

    RW.Core.Add Pre To Report    DMS migration job describe summary:
    RW.Core.Add Pre To Report    ${result.stdout}

Optional Error Log Correlation for DMS in `${GCP_PROJECT_ID}`
    [Documentation]    When unhealthy jobs were flagged, queries Cloud Logging for recent DMS-related error entries to speed up triage.
    [Tags]    GCP    DMS    logging    access:read-only    data:logs-regexp

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=fetch-dms-error-logs.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ...    show_in_rwl_cheatsheet=false
    ...    cmd_override=./fetch-dms-error-logs.sh

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat fetch_dms_error_logs_issues.json
    ...    env=${env}
    ...    include_in_history=false

    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for DMS error log issues; defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END

    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=No recent ERROR-level DMS logs when migrations are healthy.
            ...    actual=Recent DMS-related error log entries were found in the project.
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END

    RW.Core.Add Pre To Report    DMS error log correlation:
    RW.Core.Add Pre To Report    ${result.stdout}


*** Keywords ***
Suite Initialization
    ${gcp_credentials}=    RW.Core.Import Secret    gcp_credentials
    ...    type=string
    ...    description=GCP service account JSON with read-only access to DMS, Monitoring, and Logging.
    ...    pattern=\w*
    ${GCP_PROJECT_ID}=    RW.Core.Import User Variable    GCP_PROJECT_ID
    ...    type=string
    ...    description=GCP project ID that owns the DMS migration jobs.
    ...    pattern=\w*
    ${GCP_DMS_LOCATION}=    RW.Core.Import User Variable    GCP_DMS_LOCATION
    ...    type=string
    ...    description=DMS regional location passed to gcloud --region (for example us-central1).
    ...    pattern=\w*
    ${DMS_JOB_NAMES}=    RW.Core.Import User Variable    DMS_JOB_NAMES
    ...    type=string
    ...    description=Comma-separated migration job IDs, or All to evaluate every job in the location.
    ...    pattern=.*
    ...    default=All
    ${REPLICATION_LAG_SEC_THRESHOLD}=    RW.Core.Import User Variable    REPLICATION_LAG_SEC_THRESHOLD
    ...    type=string
    ...    description=Alert when migration_job/max_replica_sec_lag exceeds this many seconds during CDC.
    ...    pattern=^\d+$
    ...    default=300
    ${REPLICATION_LAG_BYTES_THRESHOLD}=    RW.Core.Import User Variable    REPLICATION_LAG_BYTES_THRESHOLD
    ...    type=string
    ...    description=Optional byte lag threshold; set 0 to disable bytes lag issues.
    ...    pattern=^\d+$
    ...    default=0
    ${DMS_STUCK_MINUTES}=    RW.Core.Import User Variable    DMS_STUCK_MINUTES
    ...    type=string
    ...    description=Minutes in a transitional or non-CDC RUNNING phase before raising a stuck warning.
    ...    pattern=^\d+$
    ...    default=120
    ${DMS_OPERATION_STUCK_MINUTES}=    RW.Core.Import User Variable    DMS_OPERATION_STUCK_MINUTES
    ...    type=string
    ...    description=Minutes an incomplete DMS operation may run before it is treated as stuck.
    ...    pattern=^\d+$
    ...    default=45
    ${DMS_OPERATION_LIMIT}=    RW.Core.Import User Variable    DMS_OPERATION_LIMIT
    ...    type=string
    ...    description=Maximum operations returned by gcloud database-migration operations list.
    ...    pattern=^\d+$
    ...    default=50
    ${DMS_LOG_LOOKBACK}=    RW.Core.Import User Variable    DMS_LOG_LOOKBACK
    ...    type=string
    ...    description=Logging freshness window for optional DMS error correlation (for example 1h or 30m).
    ...    pattern=\w+
    ...    default=1h
    ${PATH_VAL}=    Get Environment Variable    PATH
    Set Suite Variable    ${GCP_PROJECT_ID}    ${GCP_PROJECT_ID}
    Set Suite Variable    ${GCP_DMS_LOCATION}    ${GCP_DMS_LOCATION}
    Set Suite Variable    ${DMS_JOB_NAMES}    ${DMS_JOB_NAMES}
    Set Suite Variable    ${REPLICATION_LAG_SEC_THRESHOLD}    ${REPLICATION_LAG_SEC_THRESHOLD}
    Set Suite Variable    ${REPLICATION_LAG_BYTES_THRESHOLD}    ${REPLICATION_LAG_BYTES_THRESHOLD}
    Set Suite Variable    ${DMS_STUCK_MINUTES}    ${DMS_STUCK_MINUTES}
    Set Suite Variable    ${DMS_OPERATION_STUCK_MINUTES}    ${DMS_OPERATION_STUCK_MINUTES}
    Set Suite Variable    ${DMS_OPERATION_LIMIT}    ${DMS_OPERATION_LIMIT}
    Set Suite Variable    ${DMS_LOG_LOOKBACK}    ${DMS_LOG_LOOKBACK}
    Set Suite Variable    ${gcp_credentials}    ${gcp_credentials}
    ${env}=    Create Dictionary
    ...    GCP_PROJECT_ID=${GCP_PROJECT_ID}
    ...    GCP_DMS_LOCATION=${GCP_DMS_LOCATION}
    ...    DMS_JOB_NAMES=${DMS_JOB_NAMES}
    ...    REPLICATION_LAG_SEC_THRESHOLD=${REPLICATION_LAG_SEC_THRESHOLD}
    ...    REPLICATION_LAG_BYTES_THRESHOLD=${REPLICATION_LAG_BYTES_THRESHOLD}
    ...    DMS_STUCK_MINUTES=${DMS_STUCK_MINUTES}
    ...    DMS_OPERATION_STUCK_MINUTES=${DMS_OPERATION_STUCK_MINUTES}
    ...    DMS_OPERATION_LIMIT=${DMS_OPERATION_LIMIT}
    ...    DMS_LOG_LOOKBACK=${DMS_LOG_LOOKBACK}
    ...    CLOUDSDK_CORE_PROJECT=${GCP_PROJECT_ID}
    ...    GOOGLE_APPLICATION_CREDENTIALS=./${gcp_credentials.key}
    ...    PATH=${PATH_VAL}
    Set Suite Variable    ${env}    ${env}
