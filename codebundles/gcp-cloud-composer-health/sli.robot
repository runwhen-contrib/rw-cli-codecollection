*** Settings ***
Documentation       Scores GCP Cloud Composer health as a value between 0 (completely failing) and 1 (fully passing) by averaging binary sub-scores across environment state, configuration, DAG/scheduler, worker/queue, and error-log dimensions.
Metadata            Author    rw-codebundle-agent
Metadata            Display Name    GCP Cloud Composer Health
Metadata            Supports    GCP

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             OperatingSystem
Library             Collections

Suite Setup         Suite Initialization

*** Tasks ***
Score Cloud Composer Environment State in GCP Project `${GCP_PROJECT_ID}`
    [Documentation]    Scores 1 if every Cloud Composer environment is RUNNING (no environment-state issues), 0 otherwise.
    [Tags]    gcloud    composer    gcp    ${GCP_PROJECT_ID}    access:read-only    data:config
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check_env_state.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=300
    ${issues_output}=    RW.CLI.Run Cli
    ...    cmd=cat env_state_issues.json | jq length
    ...    env=${env}
    ${count}=    Set Variable    ${issues_output.stdout.strip()}
    ${count}=    Set Variable If    '${count}' == ''    0    ${count}
    ${state_score}=    Evaluate    1 if int(${count}) == 0 else 0
    Set Suite Variable    ${state_score}
    RW.Core.Push Metric    ${state_score}    sub_name=environment_health

Score Cloud Composer Configuration Health in GCP Project `${GCP_PROJECT_ID}`
    [Documentation]    Scores 1 if no environment configuration issues (outdated image/airflow, missing web server) are found, 0 otherwise.
    [Tags]    gcloud    composer    gcp    ${GCP_PROJECT_ID}    access:read-only    data:config
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=fetch_env_config.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=300
    ${issues_output}=    RW.CLI.Run Cli
    ...    cmd=cat env_config_issues.json | jq length
    ...    env=${env}
    ${count}=    Set Variable    ${issues_output.stdout.strip()}
    ${count}=    Set Variable If    '${count}' == ''    0    ${count}
    ${config_score}=    Evaluate    1 if int(${count}) == 0 else 0
    Set Suite Variable    ${config_score}
    RW.Core.Push Metric    ${config_score}    sub_name=config_health

Score Cloud Composer DAG and Scheduler Health in GCP Project `${GCP_PROJECT_ID}`
    [Documentation]    Scores 1 if no failed DAG runs, failing task instances, or scheduler issues are found, 0 otherwise.
    [Tags]    gcloud    composer    airflow    gcp    ${GCP_PROJECT_ID}    access:read-only    data:runtime
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check_jobs_and_scheduler.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=900
    ${issues_output}=    RW.CLI.Run Cli
    ...    cmd=cat jobs_scheduler_issues.json | jq length
    ...    env=${env}
    ${count}=    Set Variable    ${issues_output.stdout.strip()}
    ${count}=    Set Variable If    '${count}' == ''    0    ${count}
    ${jobs_score}=    Evaluate    1 if int(${count}) == 0 else 0
    Set Suite Variable    ${jobs_score}
    RW.Core.Push Metric    ${jobs_score}    sub_name=dag_scheduler_health

Score Cloud Composer Worker and Queue Health in GCP Project `${GCP_PROJECT_ID}`
    [Documentation]    Scores 1 if no queue backlogs or worker provisioning issues are found, 0 otherwise.
    [Tags]    gcloud    composer    airflow    gcp    ${GCP_PROJECT_ID}    access:read-only    data:runtime
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check_workers_and_queues.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=900
    ${issues_output}=    RW.CLI.Run Cli
    ...    cmd=cat workers_queues_issues.json | jq length
    ...    env=${env}
    ${count}=    Set Variable    ${issues_output.stdout.strip()}
    ${count}=    Set Variable If    '${count}' == ''    0    ${count}
    ${worker_score}=    Evaluate    1 if int(${count}) == 0 else 0
    Set Suite Variable    ${worker_score}
    RW.Core.Push Metric    ${worker_score}    sub_name=worker_queue_health

Score Cloud Composer Error Log Health in GCP Project `${GCP_PROJECT_ID}`
    [Documentation]    Scores 1 if no ERROR or higher severity environment log entries are found, 0 otherwise.
    [Tags]    gcloud    composer    gcp    ${GCP_PROJECT_ID}    access:read-only    data:logs-config
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=get_error_logs.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=300
    ${issues_output}=    RW.CLI.Run Cli
    ...    cmd=cat error_logs_issues.json | jq length
    ...    env=${env}
    ${count}=    Set Variable    ${issues_output.stdout.strip()}
    ${count}=    Set Variable If    '${count}' == ''    0    ${count}
    ${logs_score}=    Evaluate    1 if int(${count}) == 0 else 0
    Set Suite Variable    ${logs_score}
    RW.Core.Push Metric    ${logs_score}    sub_name=error_log_health

Generate Aggregate Cloud Composer Health Score for `${GCP_PROJECT_ID}`
    [Documentation]    Averages the environment, configuration, DAG/scheduler, worker/queue, and error-log sub-scores into a single 0-1 health metric.
    [Tags]    gcloud    composer    gcp    ${GCP_PROJECT_ID}    access:read-only    data:metrics
    ${health_score}=    Evaluate    (${state_score} + ${config_score} + ${jobs_score} + ${worker_score} + ${logs_score}) / 5
    ${health_score}=    Convert to Number    ${health_score}    2
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
    ...    description=The GCP Project ID that contains the Cloud Composer environments.
    ...    pattern=\w*
    ...    example=myproject-ID
    ${ENV_NAME}=    RW.Core.Import User Variable    ENV_NAME
    ...    type=string
    ...    description=Optional: pin monitoring to a single Composer environment name; defaults to 'All' (auto-discover).
    ...    pattern=\w*
    ...    default=All
    ${LOCATIONS}=    RW.Core.Import User Variable    LOCATIONS
    ...    type=string
    ...    description=Comma-separated GCP regions to search for Composer environments during discovery.
    ...    pattern=^[a-z0-9-,]+$
    ...    default=us-central1
    ${LOG_LOOKBACK_WINDOW_DAYS}=    RW.Core.Import User Variable    LOG_LOOKBACK_WINDOW_DAYS
    ...    type=string
    ...    description=Number of days back to scan Cloud Logging for error entries.
    ...    pattern=^\d+$
    ...    default=14
    ${STALE_QUEUE_AGE_MINUTES}=    RW.Core.Import User Variable    STALE_QUEUE_AGE_MINUTES
    ...    type=string
    ...    description=Age in minutes after which a queued task instance is considered stale/backlogged.
    ...    pattern=^\d+$
    ...    default=60
    ${OS_PATH}=    Get Environment Variable    PATH
    Set Suite Variable    ${GCP_PROJECT_ID}    ${GCP_PROJECT_ID}
    Set Suite Variable    ${ENV_NAME}    ${ENV_NAME}
    Set Suite Variable    ${LOCATIONS}    ${LOCATIONS}
    Set Suite Variable    ${LOG_LOOKBACK_WINDOW_DAYS}    ${LOG_LOOKBACK_WINDOW_DAYS}
    Set Suite Variable    ${STALE_QUEUE_AGE_MINUTES}    ${STALE_QUEUE_AGE_MINUTES}
    Set Suite Variable    ${gcp_credentials}    ${gcp_credentials}
    Set Suite Variable
    ...    ${env}
    ...    {"CLOUDSDK_CORE_PROJECT":"${GCP_PROJECT_ID}","PATH":"$PATH:${OS_PATH}","GCP_PROJECT_ID":"${GCP_PROJECT_ID}","ENV_NAME":"${ENV_NAME}","LOCATIONS":"${LOCATIONS}","LOG_LOOKBACK_WINDOW_DAYS":"${LOG_LOOKBACK_WINDOW_DAYS}","STALE_QUEUE_AGE_MINUTES":"${STALE_QUEUE_AGE_MINUTES}"}
    RW.CLI.Run CLI
    ...    cmd=gcloud auth activate-service-account --key-file="./${gcp_credentials.key}" || true
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
