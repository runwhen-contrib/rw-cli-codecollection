*** Settings ***
Documentation       Monitors BigQuery quota and capacity health including slot utilization, storage quotas, query per-day limits, and dataset/table count limits.
Metadata            Author    rw-codebundle-agent
Metadata            Display Name    GCP BigQuery Quota Health
Metadata            Supports    GCP,BigQuery,Quota
Force Tags          GCP    BigQuery    Quota    Capacity    Health

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             OperatingSystem
Library             Collections

Suite Setup         Suite Initialization


*** Tasks ***
Check BigQuery Slot Reservation Utilization for `${GCP_PROJECT_ID}`
    [Documentation]    Queries the BigQuery Reservation API and Cloud Monitoring to check slot utilization against purchased reservation capacity and raise issues when utilization exceeds the configured threshold.
    [Tags]    gcp    bigquery    quota    slots    data:metrics    access:read-only
    ${slot_result}=    RW.CLI.Run Bash File
    ...    bash_file=check_slot_utilization.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    show_in_rwl_cheatsheet=true
    ...    timeout_seconds=180
    ...    cmd_override=./check_slot_utilization.sh
    ${slot_issues}=    RW.CLI.Run Cli
    ...    cmd=cat slot_utilization_issues.json
    ...    env=${env}
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${slot_issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for slot utilization, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=${issue['expected']}
            ...    actual=${issue['actual']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${slot_result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    BigQuery Slot Utilization Analysis:\n${slot_result.stdout}

Check BigQuery Storage Quota for `${GCP_PROJECT_ID}`
    [Documentation]    Checks logical and physical storage against quota limits using INFORMATION_SCHEMA and Cloud Monitoring and raises issues when total storage exceeds a configurable percentage of the project quota.
    [Tags]    gcp    bigquery    quota    storage    data:metrics    access:read-only
    ${storage_result}=    RW.CLI.Run Bash File
    ...    bash_file=check_storage_quota.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    show_in_rwl_cheatsheet=true
    ...    timeout_seconds=180
    ...    cmd_override=./check_storage_quota.sh
    ${storage_issues}=    RW.CLI.Run Cli
    ...    cmd=cat storage_quota_issues.json
    ...    env=${env}
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${storage_issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for storage quota, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=${issue['expected']}
            ...    actual=${issue['actual']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${storage_result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    BigQuery Storage Quota Analysis:\n${storage_result.stdout}

Check BigQuery Query Per-Day Limit for `${GCP_PROJECT_ID}`
    [Documentation]    Monitors daily query counts from INFORMATION_SCHEMA against project-level per-day query limits and raises issues when the project is close to hitting the daily query cap.
    [Tags]    gcp    bigquery    quota    queries    data:metrics    access:read-only
    ${query_result}=    RW.CLI.Run Bash File
    ...    bash_file=check_query_daily_limit.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    show_in_rwl_cheatsheet=true
    ...    timeout_seconds=180
    ...    cmd_override=./check_query_daily_limit.sh
    ${query_issues}=    RW.CLI.Run Cli
    ...    cmd=cat query_daily_limit_issues.json
    ...    env=${env}
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${query_issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for query daily limit, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=${issue['expected']}
            ...    actual=${issue['actual']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${query_result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    BigQuery Query Per-Day Limit Analysis:\n${query_result.stdout}

Check BigQuery Dataset and Table Limits for `${GCP_PROJECT_ID}`
    [Documentation]    Counts datasets and tables across the project, checks them against GCP limits (10k tables per dataset, 10k datasets per project), and raises issues when approaching limits.
    [Tags]    gcp    bigquery    quota    dataset    data:config    access:read-only
    ${limits_result}=    RW.CLI.Run Bash File
    ...    bash_file=check_dataset_table_limits.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    show_in_rwl_cheatsheet=true
    ...    timeout_seconds=180
    ...    cmd_override=./check_dataset_table_limits.sh
    ${limits_issues}=    RW.CLI.Run Cli
    ...    cmd=cat dataset_table_limit_issues.json
    ...    env=${env}
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${limits_issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for dataset/table limits, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=${issue['expected']}
            ...    actual=${issue['actual']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${limits_result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    BigQuery Dataset and Table Limits Analysis:\n${limits_result.stdout}

Generate BigQuery Quota Health Summary for `${GCP_PROJECT_ID}`
    [Documentation]    Produces a consolidated quota health summary including slot utilization percentage, storage versus quota, daily query count, and dataset/table counts.
    [Tags]    gcp    bigquery    quota    summary    data:config    access:read-only
    ${summary_result}=    RW.CLI.Run Bash File
    ...    bash_file=generate_quota_summary.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    show_in_rwl_cheatsheet=true
    ...    timeout_seconds=180
    ...    cmd_override=./generate_quota_summary.sh
    ${summary_output}=    RW.CLI.Run Cli
    ...    cmd=cat quota_summary.json
    ...    env=${env}
    RW.Core.Add Pre To Report    BigQuery Quota Health Summary:\n${summary_output.stdout}
    RW.Core.Add Pre To Report    Commands Used:\n${summary_result.cmd}


*** Keywords ***
Suite Initialization
    ${gcp_credentials}=    RW.Core.Import Secret    gcp_credentials
    ...    type=string
    ...    description=GCP service account JSON key used to authenticate with GCP APIs.
    ...    pattern=\w*
    ...    example={"type": "service_account","project_id":"myproject-ID"}
    ${GCP_PROJECT_ID}=    RW.Core.Import User Variable    GCP_PROJECT_ID
    ...    type=string
    ...    description=GCP Project ID containing BigQuery resources.
    ...    pattern=\w*
    ...    example=my-gcp-project
    ${SLOT_UTILIZATION_THRESHOLD}=    RW.Core.Import User Variable    SLOT_UTILIZATION_THRESHOLD
    ...    type=string
    ...    description=Slot utilization percentage that triggers an alert.
    ...    pattern=^\d+(\.\d+)?$
    ...    default=80
    ${STORAGE_QUOTA_THRESHOLD}=    RW.Core.Import User Variable    STORAGE_QUOTA_THRESHOLD
    ...    type=string
    ...    description=Storage usage percentage of quota that triggers an alert.
    ...    pattern=^\d+(\.\d+)?$
    ...    default=85
    ${DAILY_QUERY_THRESHOLD}=    RW.Core.Import User Variable    DAILY_QUERY_THRESHOLD
    ...    type=string
    ...    description=Daily query count percentage of limit that triggers an alert.
    ...    pattern=^\d+(\.\d+)?$
    ...    default=80
    ${DATASET_TABLE_THRESHOLD}=    RW.Core.Import User Variable    DATASET_TABLE_THRESHOLD
    ...    type=string
    ...    description=Dataset/table count percentage of max that triggers an alert.
    ...    pattern=^\d+(\.\d+)?$
    ...    default=80
    ${OS_PATH}=    Get Environment Variable    PATH
    Set Suite Variable    ${GCP_PROJECT_ID}    ${GCP_PROJECT_ID}
    Set Suite Variable    ${SLOT_UTILIZATION_THRESHOLD}    ${SLOT_UTILIZATION_THRESHOLD}
    Set Suite Variable    ${STORAGE_QUOTA_THRESHOLD}    ${STORAGE_QUOTA_THRESHOLD}
    Set Suite Variable    ${DAILY_QUERY_THRESHOLD}    ${DAILY_QUERY_THRESHOLD}
    Set Suite Variable    ${DATASET_TABLE_THRESHOLD}    ${DATASET_TABLE_THRESHOLD}
    Set Suite Variable    ${gcp_credentials}    ${gcp_credentials}
    Set Suite Variable
    ...    ${env}
    ...    {"PATH":"$PATH:${OS_PATH}","GCP_PROJECT_ID":"${GCP_PROJECT_ID}","SLOT_UTILIZATION_THRESHOLD":"${SLOT_UTILIZATION_THRESHOLD}","STORAGE_QUOTA_THRESHOLD":"${STORAGE_QUOTA_THRESHOLD}","DAILY_QUERY_THRESHOLD":"${DAILY_QUERY_THRESHOLD}","DATASET_TABLE_THRESHOLD":"${DATASET_TABLE_THRESHOLD}"}
    RW.CLI.Run CLI
    ...    cmd=gcloud auth activate-service-account --key-file="./${gcp_credentials.key}" || true
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
