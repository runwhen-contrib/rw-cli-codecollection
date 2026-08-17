*** Settings ***
Documentation       Monitors GCP Cloud Composer (Managed Airflow) environments for overall health: environment state, live job and queue states, configuration drift, and error logs.
Metadata            Author    rw-codebundle-agent
Metadata            Display Name    GCP Cloud Composer Health
Metadata            Supports    GCP,Cloud Composer,Airflow

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             OperatingSystem
Library             Collections

Suite Setup         Suite Initialization

Force Tags          gcp    composer    airflow

*** Tasks ***
Check Cloud Composer Environment Health State in GCP Project `${GCP_PROJECT_ID}`
    [Documentation]    Lists all Cloud Composer environments in the project and flags any that are not in a healthy RUNNING state (ERROR, CREATING, UPDATING, DELETING, or degraded).
    [Tags]    gcloud    composer    gcp    ${GCP_PROJECT_ID}    access:read-only    data:config
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check_env_state.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    show_in_rwl_cheatsheet=true
    ...    timeout_seconds=300
    ...    cmd_override=./check_env_state.sh
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat env_state_issues.json
    ...    env=${env}
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for environment state, defaulting to empty list.    WARN
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
    RW.Core.Add Pre To Report    Cloud Composer Environment State Analysis:\n${result.stdout}

Fetch Cloud Composer Environment Configurations in GCP Project `${GCP_PROJECT_ID}`
    [Documentation]    Dumps full environment configuration (airflow version, software config, scheduler/worker/node counts, web server, image version, networking) and flags missing or misconfigured settings, including environments using outdated or non-LTS airflow versions.
    [Tags]    gcloud    composer    gcp    ${GCP_PROJECT_ID}    access:read-only    data:config
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=fetch_env_config.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    show_in_rwl_cheatsheet=true
    ...    timeout_seconds=300
    ...    cmd_override=./fetch_env_config.sh
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat env_config_issues.json
    ...    env=${env}
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for environment config, defaulting to empty list.    WARN
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
    RW.Core.Add Pre To Report    Cloud Composer Environment Configurations:\n${result.stdout}

Check Cloud Composer DAG and Scheduler Health in GCP Project `${GCP_PROJECT_ID}`
    [Documentation]    Checks live job states across environments: failed DAG runs, failing task instances, DAG list risks, and scheduler jobs; flags broken DAGs or a non-operational scheduler.
    [Tags]    gcloud    composer    airflow    gcp    ${GCP_PROJECT_ID}    access:read-only    data:runtime
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check_jobs_and_scheduler.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    show_in_rwl_cheatsheet=true
    ...    timeout_seconds=900
    ...    cmd_override=./check_jobs_and_scheduler.sh
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat jobs_scheduler_issues.json
    ...    env=${env}
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for jobs and scheduler, defaulting to empty list.    WARN
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
    RW.Core.Add Pre To Report    Cloud Composer DAG and Scheduler Analysis:\n${result.stdout}

Check Cloud Composer Worker and Queue Health in GCP Project `${GCP_PROJECT_ID}`
    [Documentation]    Checks Airflow queue and worker states: size of the task-instance queue, tasks queued vs running, number of healthy workers, and stale queued tasks; flags queue backlogs or under/over-provisioned workers.
    [Tags]    gcloud    composer    airflow    gcp    ${GCP_PROJECT_ID}    access:read-only    data:runtime
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check_workers_and_queues.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    show_in_rwl_cheatsheet=true
    ...    timeout_seconds=900
    ...    cmd_override=./check_workers_and_queues.sh
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat workers_queues_issues.json
    ...    env=${env}
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for workers and queues, defaulting to empty list.    WARN
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
    RW.Core.Add Pre To Report    Cloud Composer Worker and Queue Analysis:\n${result.stdout}

Get Error Logs for Cloud Composer Environments in GCP Project `${GCP_PROJECT_ID}`
    [Documentation]    Scans Cloud Logging for ERROR and higher severity entries for composer environments over the lookback window and groups them per environment, surfacing the most common failures.
    [Tags]    gcloud    composer    gcp    ${GCP_PROJECT_ID}    access:read-only    data:logs-config
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=get_error_logs.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    show_in_rwl_cheatsheet=true
    ...    timeout_seconds=300
    ...    cmd_override=./get_error_logs.sh
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat error_logs_issues.json
    ...    env=${env}
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for error logs, defaulting to empty list.    WARN
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
    RW.Core.Add Pre To Report    Cloud Composer Error Log Analysis:\n${result.stdout}

Generate Cloud Composer Health Summary for GCP Project `${GCP_PROJECT_ID}`
    [Documentation]    Aggregates environment state, job health, worker/queue health, and error-log findings into a normalized summary table and next-steps for each environment in the project.
    [Tags]    gcloud    composer    gcp    ${GCP_PROJECT_ID}    access:read-only    data:mix
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=composer_health_summary.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    show_in_rwl_cheatsheet=true
    ...    timeout_seconds=300
    ...    cmd_override=./composer_health_summary.sh
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat composer_health_summary_issues.json
    ...    env=${env}
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for health summary, defaulting to empty list.    WARN
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
    RW.Core.Add Pre To Report    Cloud Composer Health Summary:\n${result.stdout}

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
