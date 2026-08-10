*** Settings ***
Documentation       Identify over-utilized, poorly-performing, or long-running-query Cloud SQL instances in a GCP project to help operators right-size instances and detect performance degradation before it becomes an availability incident
Metadata            Author    rw-codebundle-agent
Metadata            Display Name    GCP Cloud SQL Performance
Metadata            Supports    GCP,Cloud SQL,SQL,Performance
Force Tags          GCP    Cloud SQL    SQL    Performance

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             OperatingSystem
Library             Collections

Suite Setup         Suite Initialization

*** Tasks ***
Review Cloud SQL Instance Utilization in GCP Project `${GCP_PROJECT_ID}`
    [Documentation]    Evaluates CPU, memory, and disk utilization for each Cloud SQL instance via Cloud Monitoring metrics over the look-back window, flagging instances consistently above CPU_THRESHOLD_PERCENT.
    [Tags]    gcloud    sql    monitoring    gcp    ${GCP_PROJECT_ID}    access:read-only    data:metrics
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=review_utilization.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=300
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./review_utilization.sh
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat utilization_issues.json
    ...    env=${env}
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for utilization, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=${issue['expected']}
            ...    actual=${issue['actual']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    Cloud SQL Utilization Analysis:\n${result.stdout}

Identify Cloud SQL Performance Issues in GCP Project `${GCP_PROJECT_ID}`
    [Documentation]    Analyzes throughput and IOPS metrics from Cloud Monitoring to flag instances with sustained high traffic, throughput spikes, or noisy traffic patterns over the look-back window.
    [Tags]    gcloud    sql    monitoring    gcp    ${GCP_PROJECT_ID}    access:read-only    data:metrics
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=analyze_performance.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=300
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./analyze_performance.sh
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat performance_issues.json
    ...    env=${env}
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for performance, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=${issue['expected']}
            ...    actual=${issue['actual']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    Cloud SQL Performance Analysis:\n${result.stdout}

Identify Long Running Queries for Cloud SQL Instances in GCP Project `${GCP_PROJECT_ID}`
    [Documentation]    Queries Cloud SQL instance logs for queries whose duration exceeds LONG_QUERY_SECONDS and reports the offending SQL, degrading gracefully with a note when query logs are unavailable.
    [Tags]    gcloud    sql    logging    gcp    ${GCP_PROJECT_ID}    access:read-only    data:logs-query
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=find_long_running_queries.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=300
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./find_long_running_queries.sh
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat long_query_issues.json
    ...    env=${env}
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for long running queries, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=${issue['expected']}
            ...    actual=${issue['actual']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    Cloud SQL Long Running Query Analysis:\n${result.stdout}

Check Cloud SQL Instance Storage Growth in GCP Project `${GCP_PROJECT_ID}`
    [Documentation]    Compares used storage to configured capacity for each Cloud SQL instance and flags instances at risk of running out of disk, especially high-fill instances without automatic storage increase.
    [Tags]    gcloud    sql    monitoring    gcp    ${GCP_PROJECT_ID}    access:read-only    data:metrics-config
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check_storage_growth.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=300
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./check_storage_growth.sh
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat storage_issues.json
    ...    env=${env}
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for storage growth, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=${issue['expected']}
            ...    actual=${issue['actual']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    Cloud SQL Storage Growth Analysis:\n${result.stdout}

*** Keywords ***
Suite Initialization
    ${gcp_credentials}=    RW.Core.Import Secret    gcp_credentials
    ...    type=string
    ...    description=GCP service account json used to authenticate with GCP APIs.
    ...    pattern=\w*
    ...    example={"type": "service_account","project_id":"myproject-ID", ... super secret stuff ...}
    ${GCP_PROJECT_ID}=    RW.Core.Import User Variable    GCP_PROJECT_ID
    ...    type=string
    ...    description=The GCP Project ID that hosts the Cloud SQL instances to check.
    ...    pattern=\w*
    ...    example=myproject-ID
    ${RESOURCES}=    RW.Core.Import User Variable    RESOURCES
    ...    type=string
    ...    description=Optional comma-separated list of Cloud SQL instance names to scope to. Defaults to 'All' (auto-discover all instances).
    ...    pattern=\w*
    ...    default=All
    ${CPU_THRESHOLD_PERCENT}=    RW.Core.Import User Variable    CPU_THRESHOLD_PERCENT
    ...    type=string
    ...    description=CPU utilization percentage above which an instance is flagged as over-utilized.
    ...    pattern=^\d+$
    ...    default=80
    ${UTILIZATION_HOURS}=    RW.Core.Import User Variable    UTILIZATION_HOURS
    ...    type=string
    ...    description=Look-back window (hours) for utilization and performance metrics.
    ...    pattern=^\d+$
    ...    default=6
    ${LONG_QUERY_SECONDS}=    RW.Core.Import User Variable    LONG_QUERY_SECONDS
    ...    type=string
    ...    description=Query duration (seconds) above which a query is considered long-running.
    ...    pattern=^\d+$
    ...    default=300
    ${STORAGE_FILL_THRESHOLD_PERCENT}=    RW.Core.Import User Variable    STORAGE_FILL_THRESHOLD_PERCENT
    ...    type=string
    ...    description=Storage fill percentage above which an instance without automatic storage increase is flagged.
    ...    pattern=^\d+$
    ...    default=80
    Set Suite Variable    ${GCP_PROJECT_ID}    ${GCP_PROJECT_ID}
    Set Suite Variable    ${gcp_credentials}    ${gcp_credentials}
    Set Suite Variable    ${RESOURCES}    ${RESOURCES}
    Set Suite Variable    ${CPU_THRESHOLD_PERCENT}    ${CPU_THRESHOLD_PERCENT}
    Set Suite Variable    ${UTILIZATION_HOURS}    ${UTILIZATION_HOURS}
    Set Suite Variable    ${LONG_QUERY_SECONDS}    ${LONG_QUERY_SECONDS}
    Set Suite Variable    ${STORAGE_FILL_THRESHOLD_PERCENT}    ${STORAGE_FILL_THRESHOLD_PERCENT}
    ${OS_PATH}=    Get Environment Variable    PATH
    Set Suite Variable
    ...    ${env}
    ...    {"CLOUDSDK_CORE_PROJECT":"${GCP_PROJECT_ID}","PATH":"$PATH:${OS_PATH}","GCP_PROJECT_ID":"${GCP_PROJECT_ID}","RESOURCES":"${RESOURCES}","CPU_THRESHOLD_PERCENT":"${CPU_THRESHOLD_PERCENT}","UTILIZATION_HOURS":"${UTILIZATION_HOURS}","LONG_QUERY_SECONDS":"${LONG_QUERY_SECONDS}","STORAGE_FILL_THRESHOLD_PERCENT":"${STORAGE_FILL_THRESHOLD_PERCENT}"}
    RW.CLI.Run CLI
    ...    cmd=gcloud auth activate-service-account --key-file="./${gcp_credentials.key}" || true
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
