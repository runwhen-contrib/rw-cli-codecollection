*** Settings ***
Documentation       Analyzes GCP Cloud Composer (Managed Airflow) worker, scheduler, and queue utilization to detect over-provisioning, capacity shortfalls, and usage deltas from a configurable normal baseline so environments run cost-efficiently without sacrificing job health.
Metadata            Author    rw-codebundle-agent
Metadata            Display Name    GCP Cloud Composer Performance & Capacity
Metadata            Supports    GCP,Cloud Composer,Airflow,Performance,Capacity,Utilization,Monitoring
Force Tags          GCP    Cloud Composer    Performance    Capacity    Utilization    Monitoring

Library    String
Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             OperatingSystem
Library             Collections

Suite Setup         Suite Initialization


*** Tasks ***
Analyze Cloud Composer Worker Utilization for Environments in `${GCP_PROJECT_ID}`
    [Documentation]    Computes worker CPU/memory utilization and active task throughput over the configured lookback window from Cloud Monitoring, flagging workers that are consistently saturated and may cause task backlogs.
    [Tags]    GCP    Composer    Worker    Utilization    Capacity    data:metrics    access:read-only
    FOR    ${env_name}    IN    @{RESOURCE_LIST}
        ${result}=    RW.CLI.Run Bash File
        ...    bash_file=analyze_worker_utilization.sh
        ...    env=${env}
        ...    secret_file__gcp_credentials=${gcp_credentials}
        ...    timeout_seconds=180
        ...    include_in_history=false
        ...    show_in_rwl_cheatsheet=true
        ...    cmd_override=ENV_NAME="${env_name}" GCP_PROJECT_ID="${GCP_PROJECT_ID}" ./analyze_worker_utilization.sh
        ${issues_json}=    RW.CLI.Run Cli
        ...    cmd=cat worker_utilization_issues.json
        ...    env=${env}
        ...    timeout_seconds=30
        ...    include_in_history=false
        TRY
            ${issue_list}=    Evaluate    json.loads(r'''${issues_json.stdout}''')    json
        EXCEPT
            Log    Failed to parse worker utilization issues JSON; defaulting to empty.    WARN
            ${issue_list}=    Create List
        END
        IF    len(@{issue_list}) > 0
            FOR    ${issue}    IN    @{issue_list}
                RW.Core.Add Issue
                ...    severity=${issue['severity']}
                ...    expected=${issue['expected']}
                ...    actual=${issue['actual']}
                ...    title=${issue['title']}
                ...    details=${issue['details']}
                ...    next_steps=${issue['next_steps']}
                ...    reproduce_hint=${result.cmd}
            END
        END
        RW.Core.Add Pre To Report    ${result.stdout}
    END
    RW.Core.Add Pre To Report    Worker utilization analysis complete for discovered environments.

Analyze Cloud Composer Scheduler and Queue Utilization for Environments in `${GCP_PROJECT_ID}`
    [Documentation]    Measures scheduler heartbeat activity and the task-instance queue depth over the window, flagging scheduler saturation or persistent queue backlogs that indicate insufficient capacity.
    [Tags]    GCP    Composer    Scheduler    Queue    Backlog    data:metrics    access:read-only
    FOR    ${env_name}    IN    @{RESOURCE_LIST}
        ${result}=    RW.CLI.Run Bash File
        ...    bash_file=analyze_scheduler_and_queues.sh
        ...    env=${env}
        ...    secret_file__gcp_credentials=${gcp_credentials}
        ...    timeout_seconds=180
        ...    include_in_history=false
        ...    cmd_override=ENV_NAME="${env_name}" GCP_PROJECT_ID="${GCP_PROJECT_ID}" ./analyze_scheduler_and_queues.sh
        ${issues_json}=    RW.CLI.Run Cli
        ...    cmd=cat scheduler_queue_issues.json
        ...    env=${env}
        ...    timeout_seconds=30
        ...    include_in_history=false
        TRY
            ${issue_list}=    Evaluate    json.loads(r'''${issues_json.stdout}''')    json
        EXCEPT
            Log    Failed to parse scheduler/queue issues JSON; defaulting to empty.    WARN
            ${issue_list}=    Create List
        END
        IF    len(@{issue_list}) > 0
            FOR    ${issue}    IN    @{issue_list}
                RW.Core.Add Issue
                ...    severity=${issue['severity']}
                ...    expected=${issue['expected']}
                ...    actual=${issue['actual']}
                ...    title=${issue['title']}
                ...    details=${issue['details']}
                ...    next_steps=${issue['next_steps']}
                ...    reproduce_hint=${result.cmd}
            END
        END
        RW.Core.Add Pre To Report    ${result.stdout}
    END
    RW.Core.Add Pre To Report    Scheduler and queue analysis complete for discovered environments.

Detect Cloud Composer Over-Provisioning for Environments in `${GCP_PROJECT_ID}`
    [Documentation]    Flags environments that are consistently far below the worker utilization threshold (idle capacity) over the window while still paying for that capacity, identifying candidates eligible for scale-down.
    [Tags]    GCP    Composer    Overprovisioning    Cost    Idle    data:metrics    access:read-only
    FOR    ${env_name}    IN    @{RESOURCE_LIST}
        ${result}=    RW.CLI.Run Bash File
        ...    bash_file=detect_overprovisioning.sh
        ...    env=${env}
        ...    secret_file__gcp_credentials=${gcp_credentials}
        ...    timeout_seconds=180
        ...    include_in_history=false
        ...    cmd_override=ENV_NAME="${env_name}" GCP_PROJECT_ID="${GCP_PROJECT_ID}" ./detect_overprovisioning.sh
        ${issues_json}=    RW.CLI.Run Cli
        ...    cmd=cat overprovisioning_issues.json
        ...    env=${env}
        ...    timeout_seconds=30
        ...    include_in_history=false
        TRY
            ${issue_list}=    Evaluate    json.loads(r'''${issues_json.stdout}''')    json
        EXCEPT
            Log    Failed to parse over-provisioning issues JSON; defaulting to empty.    WARN
            ${issue_list}=    Create List
        END
        IF    len(@{issue_list}) > 0
            FOR    ${issue}    IN    @{issue_list}
                RW.Core.Add Issue
                ...    severity=${issue['severity']}
                ...    expected=${issue['expected']}
                ...    actual=${issue['actual']}
                ...    title=${issue['title']}
                ...    details=${issue['details']}
                ...    next_steps=${issue['next_steps']}
                ...    reproduce_hint=${result.cmd}
            END
        END
        RW.Core.Add Pre To Report    ${result.stdout}
    END
    RW.Core.Add Pre To Report    Over-provisioning analysis complete for discovered environments.

Detect Cloud Composer Usage Deltas Over Normal Baseline for Environments in `${GCP_PROJECT_ID}`
    [Documentation]    Compares current utilization and queue behavior against the rolling baseline computed from the same environment's history over a configurable comparison window, flagging significant deltas such as sudden spikes or sustained growth that deviate from normal usage.
    [Tags]    GCP    Composer    UsageDelta    Baseline    Trend    data:metrics    access:read-only
    FOR    ${env_name}    IN    @{RESOURCE_LIST}
        ${result}=    RW.CLI.Run Bash File
        ...    bash_file=detect_usage_deltas.sh
        ...    env=${env}
        ...    secret_file__gcp_credentials=${gcp_credentials}
        ...    timeout_seconds=180
        ...    include_in_history=false
        ...    cmd_override=ENV_NAME="${env_name}" GCP_PROJECT_ID="${GCP_PROJECT_ID}" ./detect_usage_deltas.sh
        ${issues_json}=    RW.CLI.Run Cli
        ...    cmd=cat usage_delta_issues.json
        ...    env=${env}
        ...    timeout_seconds=30
        ...    include_in_history=false
        TRY
            ${issue_list}=    Evaluate    json.loads(r'''${issues_json.stdout}''')    json
        EXCEPT
            Log    Failed to parse usage delta issues JSON; defaulting to empty.    WARN
            ${issue_list}=    Create List
        END
        IF    len(@{issue_list}) > 0
            FOR    ${issue}    IN    @{issue_list}
                RW.Core.Add Issue
                ...    severity=${issue['severity']}
                ...    expected=${issue['expected']}
                ...    actual=${issue['actual']}
                ...    title=${issue['title']}
                ...    details=${issue['details']}
                ...    next_steps=${issue['next_steps']}
                ...    reproduce_hint=${result.cmd}
            END
        END
        RW.Core.Add Pre To Report    ${result.stdout}
    END
    RW.Core.Add Pre To Report    Usage delta analysis complete for discovered environments.


*** Keywords ***
Suite Initialization
    ${gcp_credentials}=    RW.Core.Import Secret    gcp_credentials
    ...    type=string
    ...    description=GCP service account json used to authenticate with GCP APIs.
    ...    pattern=\w*
    ...    example={"type": "service_account","project_id":"myproject-ID"}
    ${GCP_PROJECT_ID}=    RW.Core.Import User Variable    GCP_PROJECT_ID
    ...    type=string
    ...    description=The GCP Project ID that contains the Cloud Composer environments.
    ...    pattern=^[a-z0-9-]+$
    ...    example=myproject-id
    ${ENV_NAME}=    RW.Core.Import User Variable    ENV_NAME
    ...    type=string
    ...    description=Optional: pin analysis to a single Composer environment name; defaults to All (auto-discover).
    ...    pattern=\w*
    ...    default=All
    ${LOCATIONS}=    RW.Core.Import User Variable    LOCATIONS
    ...    type=string
    ...    description=Comma-separated GCP regions to search for Composer environments during discovery.
    ...    pattern=^[a-z0-9-,]+$
    ...    default=us-central1
    ${LOOKBACK_WINDOW_MINUTES}=    RW.Core.Import User Variable    LOOKBACK_WINDOW_MINUTES
    ...    type=string
    ...    description=Time range (minutes) of historical usage to evaluate.
    ...    pattern=^\d+$
    ...    default=1440
    ${BASELINE_WINDOW_MINUTES}=    RW.Core.Import User Variable    BASELINE_WINDOW_MINUTES
    ...    type=string
    ...    description=Comparison window (minutes) used as the normal baseline for delta detection.
    ...    pattern=^\d+$
    ...    default=10080
    ${UTILIZATION_THRESHOLD_PERCENT}=    RW.Core.Import User Variable    UTILIZATION_THRESHOLD_PERCENT
    ...    type=string
    ...    description=Upper utilization threshold (percent) above which capacity is considered saturated.
    ...    pattern=^\d+$
    ...    default=80
    ${UNDERUTILIZATION_THRESHOLD_PERCENT}=    RW.Core.Import User Variable    UNDERUTILIZATION_THRESHOLD_PERCENT
    ...    type=string
    ...    description=Lower utilization threshold (percent) below which capacity is considered over-provisioned.
    ...    pattern=^\d+$
    ...    default=20
    ${DELTA_THRESHOLD_PERCENT}=    RW.Core.Import User Variable    DELTA_THRESHOLD_PERCENT
    ...    type=string
    ...    description=Percent deviation from baseline that triggers a usage-delta issue.
    ...    pattern=^\d+$
    ...    default=50
    ${QUEUE_BACKLOG_THRESHOLD}=    RW.Core.Import User Variable    QUEUE_BACKLOG_THRESHOLD
    ...    type=string
    ...    description=Average task-instance queue depth above which a persistent backlog is flagged.
    ...    pattern=^\d+$
    ...    default=100
    ${OS_PATH}=    Get Environment Variable    PATH

    Set Suite Variable    ${GCP_PROJECT_ID}    ${GCP_PROJECT_ID}
    Set Suite Variable    ${ENV_NAME}    ${ENV_NAME}
    Set Suite Variable    ${LOCATIONS}    ${LOCATIONS}
    Set Suite Variable    ${LOOKBACK_WINDOW_MINUTES}    ${LOOKBACK_WINDOW_MINUTES}
    Set Suite Variable    ${BASELINE_WINDOW_MINUTES}    ${BASELINE_WINDOW_MINUTES}
    Set Suite Variable    ${UTILIZATION_THRESHOLD_PERCENT}    ${UTILIZATION_THRESHOLD_PERCENT}
    Set Suite Variable    ${UNDERUTILIZATION_THRESHOLD_PERCENT}    ${UNDERUTILIZATION_THRESHOLD_PERCENT}
    Set Suite Variable    ${DELTA_THRESHOLD_PERCENT}    ${DELTA_THRESHOLD_PERCENT}
    Set Suite Variable    ${QUEUE_BACKLOG_THRESHOLD}    ${QUEUE_BACKLOG_THRESHOLD}
    Set Suite Variable    ${gcp_credentials}    ${gcp_credentials}

    ${env_dict}=    Create Dictionary
    ...    GCP_PROJECT_ID=${GCP_PROJECT_ID}
    ...    ENV_NAME=${ENV_NAME}
    ...    LOCATIONS=${LOCATIONS}
    ...    LOOKBACK_WINDOW_MINUTES=${LOOKBACK_WINDOW_MINUTES}
    ...    BASELINE_WINDOW_MINUTES=${BASELINE_WINDOW_MINUTES}
    ...    UTILIZATION_THRESHOLD_PERCENT=${UTILIZATION_THRESHOLD_PERCENT}
    ...    UNDERUTILIZATION_THRESHOLD_PERCENT=${UNDERUTILIZATION_THRESHOLD_PERCENT}
    ...    DELTA_THRESHOLD_PERCENT=${DELTA_THRESHOLD_PERCENT}
    ...    QUEUE_BACKLOG_THRESHOLD=${QUEUE_BACKLOG_THRESHOLD}
    ...    GOOGLE_APPLICATION_CREDENTIALS=./${gcp_credentials.key}
    ...    PATH=${OS_PATH}
    Set Suite Variable    ${env}    ${env_dict}

    # Activate the service account once for all gcloud commands.
    RW.CLI.Run Cli
    ...    cmd=gcloud auth activate-service-account --key-file="./${gcp_credentials.key}" || true
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=60
    ...    include_in_history=false

    # Discover Composer environments (or pin to ENV_NAME).
    ${discovery}=    RW.CLI.Run Bash File
    ...    bash_file=discover_composer_environments.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=120
    ...    include_in_history=false
    RW.Core.Add Pre To Report    ${discovery.stdout}

    ${env_json}=    RW.CLI.Run Cli
    ...    cmd=cat composer_environments.json
    ...    env=${env}
    ...    timeout_seconds=30
    ...    include_in_history=false
    TRY
        ${RESOURCE_LIST}=    Evaluate    json.loads(r'''${env_json.stdout}''')    json
    EXCEPT
        Log    Failed to parse environment discovery JSON; defaulting to empty.    WARN
        ${RESOURCE_LIST}=    Create List
    END
    IF    len(@{RESOURCE_LIST}) == 0
        Log    No Composer environments discovered. Tasks will run with no iterations.    WARN
    END
    Set Suite Variable    ${RESOURCE_LIST}
