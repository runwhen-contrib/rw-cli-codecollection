*** Settings ***
Documentation       Monitors BigQuery dataset and table health including size trends, access control configuration, expiration policies, and audit logging.
Metadata            Author    rw-codebundle-agent
Metadata            Display Name    GCP BigQuery Dataset Health
Metadata            Supports    GCP,BigQuery
Force Tags          GCP    BigQuery    Dataset    Health

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             OperatingSystem
Library             DateTime
Library             Collections

Suite Setup         Suite Initialization


*** Tasks ***
Check BigQuery Table Size Trends for `${GCP_PROJECT_ID}`
    [Documentation]    Analyzes table sizes across all datasets to identify tables exceeding the configured size threshold.
    [Tags]    gcp    bigquery    dataset    data:metrics    access:read-only
    ${size_result}=    RW.CLI.Run Bash File
    ...    bash_file=check_table_size_trends.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    show_in_rwl_cheatsheet=true
    ...    timeout_seconds=180
    ...    cmd_override=./check_table_size_trends.sh
    ${size_issues}=    RW.CLI.Run Cli
    ...    cmd=cat table_size_issues.json
    ...    env=${env}
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${size_issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for table size trends, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=${issue['expected']}
            ...    actual=${issue['actual']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${size_result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    BigQuery Table Size Analysis:\n${size_result.stdout}

Check BigQuery Dataset Access Configuration for `${GCP_PROJECT_ID}`
    [Documentation]    Reviews IAM policies on all datasets to detect public access and overly permissive roles.
    [Tags]    gcp    bigquery    dataset    security    data:config    access:read-only
    ${access_result}=    RW.CLI.Run Bash File
    ...    bash_file=check_dataset_access.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    show_in_rwl_cheatsheet=true
    ...    timeout_seconds=180
    ...    cmd_override=./check_dataset_access.sh
    ${access_issues}=    RW.CLI.Run Cli
    ...    cmd=cat dataset_access_issues.json
    ...    env=${env}
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${access_issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for dataset access, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=${issue['expected']}
            ...    actual=${issue['actual']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${access_result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    BigQuery Dataset Access Analysis:\n${access_result.stdout}

Check BigQuery Table Expiration Policies for `${GCP_PROJECT_ID}`
    [Documentation]    Identifies tables without expiration timestamps and datasets without default table expiration.
    [Tags]    gcp    bigquery    dataset    retention    data:config    access:read-only
    ${expiration_result}=    RW.CLI.Run Bash File
    ...    bash_file=check_table_expiration.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    show_in_rwl_cheatsheet=true
    ...    timeout_seconds=180
    ...    cmd_override=./check_table_expiration.sh
    ${expiration_issues}=    RW.CLI.Run Cli
    ...    cmd=cat table_expiration_issues.json
    ...    env=${env}
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${expiration_issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for table expiration, defaulting to empty list.    WARN
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
    RW.Core.Add Pre To Report    BigQuery Table Expiration Analysis:\n${expiration_result.stdout}

Check BigQuery Audit Logging Configuration for `${GCP_PROJECT_ID}`
    [Documentation]    Verifies that BigQuery audit logs and log sinks are configured for the project.
    [Tags]    gcp    bigquery    logging    auditing    data:config    access:read-only
    ${audit_result}=    RW.CLI.Run Bash File
    ...    bash_file=check_audit_logging.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    show_in_rwl_cheatsheet=true
    ...    timeout_seconds=120
    ...    cmd_override=./check_audit_logging.sh
    ${audit_issues}=    RW.CLI.Run Cli
    ...    cmd=cat audit_logging_issues.json
    ...    env=${env}
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${audit_issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for audit logging, defaulting to empty list.    WARN
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
    RW.Core.Add Pre To Report    BigQuery Audit Logging Analysis:\n${audit_result.stdout}

Analyze BigQuery Table Partitioning and Clustering for `${GCP_PROJECT_ID}`
    [Documentation]    Identifies large tables lacking partitioning or clustering for optimization and cost savings.
    [Tags]    gcp    bigquery    dataset    optimization    data:config    access:read-only
    ${optimization_result}=    RW.CLI.Run Bash File
    ...    bash_file=check_table_optimization.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    show_in_rwl_cheatsheet=true
    ...    timeout_seconds=180
    ...    cmd_override=./check_table_optimization.sh
    ${optimization_issues}=    RW.CLI.Run Cli
    ...    cmd=cat table_optimization_issues.json
    ...    env=${env}
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${optimization_issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for table optimization, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=${issue['expected']}
            ...    actual=${issue['actual']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${optimization_result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    BigQuery Table Optimization Analysis:\n${optimization_result.stdout}

Generate BigQuery Dataset Health Summary Report for `${GCP_PROJECT_ID}`
    [Documentation]    Produces a consolidated dataset health summary including total datasets, tables, storage, and largest tables.
    [Tags]    gcp    bigquery    dataset    summary    data:config    access:read-only
    ${summary_result}=    RW.CLI.Run Bash File
    ...    bash_file=generate_dataset_summary.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    show_in_rwl_cheatsheet=true
    ...    timeout_seconds=180
    ...    cmd_override=./generate_dataset_summary.sh
    ${summary_output}=    RW.CLI.Run Cli
    ...    cmd=cat dataset_summary.json
    ...    env=${env}
    RW.Core.Add Pre To Report    BigQuery Dataset Health Summary:\n${summary_output.stdout}
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
    ${TABLE_SIZE_THRESHOLD_GB}=    RW.Core.Import User Variable    TABLE_SIZE_THRESHOLD_GB
    ...    type=string
    ...    description=Table size in GB above which an issue is raised.
    ...    pattern=\w*
    ...    default=100
    ${TABLE_GROWTH_THRESHOLD_PERCENT}=    RW.Core.Import User Variable    TABLE_GROWTH_THRESHOLD_PERCENT
    ...    type=string
    ...    description=Month-over-month growth percentage that triggers an alert.
    ...    pattern=\w*
    ...    default=50
    ${INCLUDE_STREAMING_BUFFER}=    RW.Core.Import User Variable    INCLUDE_STREAMING_BUFFER
    ...    type=string
    ...    description=Whether to include streaming buffer in table size calculations.
    ...    pattern=\w*
    ...    default=false
    ${OS_PATH}=    Get Environment Variable    PATH
    Set Suite Variable    ${GCP_PROJECT_ID}    ${GCP_PROJECT_ID}
    Set Suite Variable    ${TABLE_SIZE_THRESHOLD_GB}    ${TABLE_SIZE_THRESHOLD_GB}
    Set Suite Variable    ${TABLE_GROWTH_THRESHOLD_PERCENT}    ${TABLE_GROWTH_THRESHOLD_PERCENT}
    Set Suite Variable    ${INCLUDE_STREAMING_BUFFER}    ${INCLUDE_STREAMING_BUFFER}
    Set Suite Variable    ${gcp_credentials}    ${gcp_credentials}
    Set Suite Variable
    ...    ${env}
    ...    {"GOOGLE_APPLICATION_CREDENTIALS":"./${gcp_credentials.key}","PATH":"$PATH:${OS_PATH}","GCP_PROJECT_ID":"${GCP_PROJECT_ID}","TABLE_SIZE_THRESHOLD_GB":"${TABLE_SIZE_THRESHOLD_GB}","TABLE_GROWTH_THRESHOLD_PERCENT":"${TABLE_GROWTH_THRESHOLD_PERCENT}","INCLUDE_STREAMING_BUFFER":"${INCLUDE_STREAMING_BUFFER}"}