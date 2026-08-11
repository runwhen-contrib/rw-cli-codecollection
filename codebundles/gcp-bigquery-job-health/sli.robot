*** Settings ***
Documentation       This SLI measures BigQuery job health by scoring success rate, slow job count, slot contention, and error patterns. Produces a value between 0 (completely failing) and 1 (fully passing).
Metadata            Author    rw-codebundle-agent
Metadata            Display Name    GCP BigQuery Job Health
Metadata            Supports    GCP    BigQuery    Job Health

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             OperatingSystem

Suite Setup         Suite Initialization


*** Tasks ***
Check BigQuery Job Success Rate Score for `${GCP_PROJECT_ID}`
    [Documentation]    Checks the job success rate and scores it as 1 if above threshold, 0 otherwise.
    [Tags]    GCP    BigQuery    Job Health    access:read-only    data:metrics
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check_job_success_rate.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ${issues_json}=    RW.CLI.Run Cli
    ...    cmd=cat job_success_rate_output.json
    ...    env=${env}
    ...    timeout_seconds=30
    TRY
        ${issues}=    Evaluate    json.loads(r'''${issues_json.stdout}''')    json
        ${has_issues}=    Evaluate    len($issues) > 0
    EXCEPT
        Log    Failed to parse JSON, defaulting to 0.    WARN
        ${has_issues}=    Set Variable    ${TRUE}
    END
    ${success_score}=    Evaluate    0 if $has_issues else 1
    Set Global Variable    ${success_score}
    RW.Core.Push Metric    ${success_score}    sub_name=job_success_rate

Check Slow Jobs Score for `${GCP_PROJECT_ID}`
    [Documentation]    Checks for slow running jobs and scores 1 if none found, 0 otherwise.
    [Tags]    GCP    BigQuery    Performance    access:read-only    data:metrics
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=identify_slow_jobs.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ${issues_json}=    RW.CLI.Run Cli
    ...    cmd=cat slow_jobs_output.json
    ...    env=${env}
    ...    timeout_seconds=30
    TRY
        ${issues}=    Evaluate    json.loads(r'''${issues_json.stdout}''')    json
        ${has_issues}=    Evaluate    len($issues) > 0
    EXCEPT
        Log    Failed to parse JSON, defaulting to 0.    WARN
        ${has_issues}=    Set Variable    ${TRUE}
    END
    ${slow_jobs_score}=    Evaluate    0 if $has_issues else 1
    Set Global Variable    ${slow_jobs_score}
    RW.Core.Push Metric    ${slow_jobs_score}    sub_name=slow_jobs

Check Slot Contention Score for `${GCP_PROJECT_ID}`
    [Documentation]    Checks for slot contention and scores 1 if none found, 0 otherwise.
    [Tags]    GCP    BigQuery    Slot Contention    access:read-only    data:metrics
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check_slot_contention.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ${issues_json}=    RW.CLI.Run Cli
    ...    cmd=cat slot_contention_output.json
    ...    env=${env}
    ...    timeout_seconds=30
    TRY
        ${issues}=    Evaluate    json.loads(r'''${issues_json.stdout}''')    json
        ${has_issues}=    Evaluate    len($issues) > 0
    EXCEPT
        Log    Failed to parse JSON, defaulting to 0.    WARN
        ${has_issues}=    Set Variable    ${TRUE}
    END
    ${slot_score}=    Evaluate    0 if $has_issues else 1
    Set Global Variable    ${slot_score}
    RW.Core.Push Metric    ${slot_score}    sub_name=slot_contention

Generate Aggregate BigQuery Job Health Score for `${GCP_PROJECT_ID}`
    [Documentation]    Averages sub-scores into the final 0-1 health metric.
    ${health_score}=    Evaluate    (${success_score} + ${slow_jobs_score} + ${slot_score}) / 3
    ${health_score}=    Convert to Number    ${health_score}    2
    RW.Core.Add to Report    BigQuery Job Health Score for ${GCP_PROJECT_ID}: ${health_score}
    RW.Core.Push Metric    ${health_score}


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
    Set Suite Variable    ${env}    {"CLOUDSDK_BILLING_QUOTA_PROJECT":"${GCP_PROJECT_ID}","CLOUDSDK_CORE_PROJECT":"${GCP_PROJECT_ID}","PATH":"$PATH:${OS_PATH}","GCP_PROJECT_ID":"${GCP_PROJECT_ID}","JOB_LOOKBACK_HOURS":"${JOB_LOOKBACK_HOURS}","SUCCESS_RATE_THRESHOLD":"${SUCCESS_RATE_THRESHOLD}","SLOW_JOB_DURATION_MINUTES":"${SLOW_JOB_DURATION_MINUTES}","SLOT_CONTENTION_THRESHOLD":"${SLOT_CONTENTION_THRESHOLD}"}
    RW.CLI.Run CLI
    ...    cmd=gcloud auth activate-service-account --key-file="./${gcp_credentials.key}" || true
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}