*** Settings ***
Documentation       Monitors BigQuery job execution health by analyzing success/failure rates, error patterns, performance anomalies, and slot contention.
Metadata            Author    rw-codebundle-agent
Metadata            Display Name    GCP BigQuery Job Health
Metadata            Supports    GCP    BigQuery    Job Health    Query Performance
Force Tags          GCP    BigQuery    Job Health    Query Performance

Library    String
Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             OperatingSystem
Library             Collections
Suite Setup         Suite Initialization


*** Tasks ***
Check BigQuery Job Success Rate for `${GCP_PROJECT_ID}`
    [Documentation]    Queries BigQuery job history (INFORMATION_SCHEMA) to calculate the job success rate over a configurable lookback window. Raises an issue if the success rate falls below the configured threshold.
    [Tags]    GCP    BigQuery    Job Health    Success Rate    access:read-only    data:metrics
    ${success_rate_result}=    RW.CLI.Run Bash File
    ...    bash_file=check_job_success_rate.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./check_job_success_rate.sh
    ${success_issues_json}=    RW.CLI.Run Cli
    ...    cmd=cat job_success_rate_output.json
    ...    env=${env}
    ...    timeout_seconds=30
    ...    include_in_history=false
    TRY
        ${success_issues_list}=    Evaluate    json.loads(r'''${success_issues_json.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for success rate check, defaulting to empty list.    WARN
        ${success_issues_list}=    Create List
    END
    IF    len(@{success_issues_list}) > 0
        FOR    ${issue}    IN    @{success_issues_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=${issue['expected']}
            ...    actual=${issue['actual']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${success_rate_result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    BigQuery Job Success Rate Analysis:\n${success_rate_result.stdout}

Analyze Failed BigQuery Job Error Patterns for `${GCP_PROJECT_ID}`
    [Documentation]    Categorizes failed BigQuery jobs by error reason (quotaExceeded, invalidQuery, timeout, accessDenied, etc.) and raises issues for the most frequent error categories.
    [Tags]    GCP    BigQuery    Error Analysis    Job Failures    access:read-only    data:logs-config
    ${failed_jobs_result}=    RW.CLI.Run Bash File
    ...    bash_file=analyze_failed_jobs.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./analyze_failed_jobs.sh
    ${failed_issues_json}=    RW.CLI.Run Cli
    ...    cmd=cat failed_jobs_analysis_output.json
    ...    env=${env}
    ...    timeout_seconds=30
    ...    include_in_history=false
    TRY
        ${failed_issues_list}=    Evaluate    json.loads(r'''${failed_issues_json.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for failed jobs analysis, defaulting to empty list.    WARN
        ${failed_issues_list}=    Create List
    END
    IF    len(@{failed_issues_list}) > 0
        FOR    ${issue}    IN    @{failed_issues_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=${issue['expected']}
            ...    actual=${issue['actual']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${failed_jobs_result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    Failed Jobs Error Pattern Analysis:\n${failed_jobs_result.stdout}

Identify Slow Running BigQuery Jobs for `${GCP_PROJECT_ID}`
    [Documentation]    Detects BigQuery jobs that exceed a configurable duration threshold (default: 30 minutes). Raises issues for jobs that are slow, indicating potential performance or resource problems.
    [Tags]    GCP    BigQuery    Performance    Slow Jobs    access:read-only    data:metrics
    ${slow_jobs_result}=    RW.CLI.Run Bash File
    ...    bash_file=identify_slow_jobs.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./identify_slow_jobs.sh
    ${slow_issues_json}=    RW.CLI.Run Cli
    ...    cmd=cat slow_jobs_output.json
    ...    env=${env}
    ...    timeout_seconds=30
    ...    include_in_history=false
    TRY
        ${slow_issues_list}=    Evaluate    json.loads(r'''${slow_issues_json.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for slow jobs analysis, defaulting to empty list.    WARN
        ${slow_issues_list}=    Create List
    END
    IF    len(@{slow_issues_list}) > 0
        FOR    ${issue}    IN    @{slow_issues_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=${issue['expected']}
            ...    actual=${issue['actual']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${slow_jobs_result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    Slow Running Jobs Analysis:\n${slow_jobs_result.stdout}

Check BigQuery Job Slot Contention for `${GCP_PROJECT_ID}`
    [Documentation]    Analyzes slot usage from INFORMATION_SCHEMA to detect contention periods where slot demand exceeds reservation capacity. Raises issues when slot contention is detected.
    [Tags]    GCP    BigQuery    Slot Contention    Performance    access:read-only    data:metrics
    ${slot_result}=    RW.CLI.Run Bash File
    ...    bash_file=check_slot_contention.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./check_slot_contention.sh
    ${slot_issues_json}=    RW.CLI.Run Cli
    ...    cmd=cat slot_contention_output.json
    ...    env=${env}
    ...    timeout_seconds=30
    ...    include_in_history=false
    TRY
        ${slot_issues_list}=    Evaluate    json.loads(r'''${slot_issues_json.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for slot contention check, defaulting to empty list.    WARN
        ${slot_issues_list}=    Create List
    END
    IF    len(@{slot_issues_list}) > 0
        FOR    ${issue}    IN    @{slot_issues_list}
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
    RW.Core.Add Pre To Report    Slot Contention Analysis:\n${slot_result.stdout}

Generate BigQuery Job Health Summary Report for `${GCP_PROJECT_ID}`
    [Documentation]    Produces a consolidated health summary for BigQuery jobs including total jobs, success rate, failure breakdown, average duration, and slot utilization. Appends to the workspace report.
    [Tags]    GCP    BigQuery    Summary    Reporting    access:read-only    data:config
    ${summary_result}=    RW.CLI.Run Bash File
    ...    bash_file=generate_job_summary.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./generate_job_summary.sh
    RW.Core.Add Pre To Report    BigQuery Job Health Summary Report:\n${summary_result.stdout}
    ${summary_json}=    RW.CLI.Run Cli
    ...    cmd=cat job_summary_output.json
    ...    env=${env}
    ...    timeout_seconds=30
    ...    include_in_history=false
    TRY
        ${summary_data}=    Evaluate    json.loads(r'''${summary_json.stdout}''')    json
        ${total_jobs}=    Set Variable    ${summary_data['total_jobs']}
        ${success_rate}=    Set Variable    ${summary_data['success_rate']}
        RW.Core.Add To Report    BigQuery Job Health Summary - Project: ${GCP_PROJECT_ID} - Total Jobs: ${total_jobs} - Success Rate: ${success_rate}%
    EXCEPT
        Log    Failed to parse summary JSON.    WARN
    END


*** Keywords ***
Suite Initialization
    ${gcp_credentials}=    RW.Core.Import Secret    gcp_credentials
    ...    type=string
    ...    description=GCP service account json used to authenticate with GCP APIs.
    ...    pattern=\w*
    ...    example={"type": "service_account","project_id":"myproject-ID", ... super secret stuff ...}
    ${GCP_PROJECT_ID}=    RW.Core.Import User Variable    GCP_PROJECT_ID
    ...    type=string
    ...    description=The GCP project ID that contains the BigQuery jobs to monitor.
    ...    pattern=\w*
    ...    example=my-gcp-project
    ${JOB_LOOKBACK_HOURS}=    RW.Core.Import User Variable    JOB_LOOKBACK_HOURS
    ...    type=string
    ...    description=Number of hours to look back for job analysis.
    ...    pattern=\d+
    ...    default=24
    ${SUCCESS_RATE_THRESHOLD}=    RW.Core.Import User Variable    SUCCESS_RATE_THRESHOLD
    ...    type=string
    ...    description=Minimum acceptable job success rate (percentage).
    ...    pattern=\d+
    ...    default=95
    ${SLOW_JOB_DURATION_MINUTES}=    RW.Core.Import User Variable    SLOW_JOB_DURATION_MINUTES
    ...    type=string
    ...    description=Duration in minutes above which a job is considered slow.
    ...    pattern=\d+
    ...    default=30
    ${SLOT_CONTENTION_THRESHOLD}=    RW.Core.Import User Variable    SLOT_CONTENTION_THRESHOLD
    ...    type=string
    ...    description=Slot utilization percentage indicating contention.
    ...    pattern=\d+
    ...    default=80
    ${OS_PATH}=    Get Environment Variable    PATH
    Set Suite Variable    ${GCP_PROJECT_ID}    ${GCP_PROJECT_ID}
    Set Suite Variable    ${JOB_LOOKBACK_HOURS}    ${JOB_LOOKBACK_HOURS}
    Set Suite Variable    ${SUCCESS_RATE_THRESHOLD}    ${SUCCESS_RATE_THRESHOLD}
    Set Suite Variable    ${SLOW_JOB_DURATION_MINUTES}    ${SLOW_JOB_DURATION_MINUTES}
    Set Suite Variable    ${SLOT_CONTENTION_THRESHOLD}    ${SLOT_CONTENTION_THRESHOLD}
    Set Suite Variable    ${gcp_credentials}    ${gcp_credentials}
    Set Suite Variable    ${env}    {"GOOGLE_APPLICATION_CREDENTIALS":"./${gcp_credentials.key}","PATH":"$PATH:${OS_PATH}","GCP_PROJECT_ID":"${GCP_PROJECT_ID}","JOB_LOOKBACK_HOURS":"${JOB_LOOKBACK_HOURS}","SUCCESS_RATE_THRESHOLD":"${SUCCESS_RATE_THRESHOLD}","SLOW_JOB_DURATION_MINUTES":"${SLOW_JOB_DURATION_MINUTES}","SLOT_CONTENTION_THRESHOLD":"${SLOT_CONTENTION_THRESHOLD}"}