*** Settings ***
Documentation       Measures the performance and capacity health of GCP Cloud Composer environments by scoring worker capacity, queue health, and utilization balance into a value between 0 (completely failing) and 1 (fully passing).
Metadata            Author    rw-codebundle-agent
Metadata            Display Name    GCP Cloud Composer Performance & Capacity SLI
Metadata            Supports    GCP,Cloud Composer,Airflow,Performance,Capacity
Suite Setup         Suite Initialization
Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             OperatingSystem
Library             Collections
Library             String


*** Tasks ***
Compute Cloud Composer Performance Dimensions for `${GCP_PROJECT_ID}`
    [Documentation]    Computes the worker capacity, queue health, and utilization balance dimension scores by querying Cloud Monitoring for the configured window.
    [Tags]    GCP    Composer    Performance    SLI    data:metrics    access:read-only
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=compute_composer_sli.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=60
    ...    include_in_history=false
    ...    cmd_override=ENV_NAME="${ENV_NAME}" GCP_PROJECT_ID="${GCP_PROJECT_ID}" ./compute_composer_sli.sh
    RW.Core.Add Pre To Report    ${result.stdout}
    ${sli_json}=    RW.CLI.Run Cli
    ...    cmd=cat composer_sli.json
    ...    env=${env}
    ...    timeout_seconds=30
    ...    include_in_history=false
    TRY
        ${sli}=    Evaluate    json.loads(r'''${sli_json.stdout}''')    json
    EXCEPT
        Log    Failed to parse SLI JSON; defaulting to degraded scores.    WARN
        ${sli}=    Create Dictionary    worker_capacity=0    queue_health=0    utilization_balance=0    health_score=0
    END
    ${worker_capacity}=    Convert To Number    ${sli['worker_capacity']}
    ${queue_health}=    Convert To Number    ${sli['queue_health']}
    ${utilization_balance}=    Convert To Number    ${sli['utilization_balance']}
    Set Suite Variable    ${worker_capacity}
    Set Suite Variable    ${queue_health}
    Set Suite Variable    ${utilization_balance}
    RW.Core.Push Metric    ${worker_capacity}    sub_name=worker_capacity
    RW.Core.Push Metric    ${queue_health}    sub_name=queue_health
    RW.Core.Push Metric    ${utilization_balance}    sub_name=utilization_balance

Generate Cloud Composer Performance Health Score for `${GCP_PROJECT_ID}`
    [Documentation]    Aggregates the individual dimension scores into the final 0-1 health metric used for alerting.
    [Tags]    GCP    Composer    Performance    SLI    HealthScore    access:read-only
    ${health_score}=    Evaluate    (${worker_capacity} + ${queue_health} + ${utilization_balance}) / 3
    ${health_score}=    Convert To Number    ${health_score}    3
    RW.Core.Push Metric    ${health_score}


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
    ...    description=Optional: pin SLI to a single Composer environment name; defaults to All (auto-discover).
    ...    pattern=\w*
    ...    default=All
    ${LOCATIONS}=    RW.Core.Import User Variable    LOCATIONS
    ...    type=string
    ...    description=Comma-separated GCP regions to search for Composer environments during discovery.
    ...    pattern=^[a-z0-9-,]+$
    ...    default=us-central1
    ${SLI_WINDOW_MINUTES}=    RW.Core.Import User Variable    SLI_WINDOW_MINUTES
    ...    type=string
    ...    description=Time window (minutes) of usage the SLI evaluates.
    ...    pattern=^\d+$
    ...    default=60
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
    ${QUEUE_BACKLOG_THRESHOLD}=    RW.Core.Import User Variable    QUEUE_BACKLOG_THRESHOLD
    ...    type=string
    ...    description=Average task-instance queue depth above which a persistent backlog is flagged.
    ...    pattern=^\d+$
    ...    default=100
    ${OS_PATH}=    Get Environment Variable    PATH
    Set Suite Variable    ${GCP_PROJECT_ID}    ${GCP_PROJECT_ID}
    Set Suite Variable    ${ENV_NAME}    ${ENV_NAME}
    Set Suite Variable    ${LOCATIONS}    ${LOCATIONS}
    Set Suite Variable    ${SLI_WINDOW_MINUTES}    ${SLI_WINDOW_MINUTES}
    Set Suite Variable    ${UTILIZATION_THRESHOLD_PERCENT}    ${UTILIZATION_THRESHOLD_PERCENT}
    Set Suite Variable    ${UNDERUTILIZATION_THRESHOLD_PERCENT}    ${UNDERUTILIZATION_THRESHOLD_PERCENT}
    Set Suite Variable    ${QUEUE_BACKLOG_THRESHOLD}    ${QUEUE_BACKLOG_THRESHOLD}
    Set Suite Variable    ${gcp_credentials}    ${gcp_credentials}
    ${env_dict}=    Create Dictionary
    ...    GCP_PROJECT_ID=${GCP_PROJECT_ID}
    ...    ENV_NAME=${ENV_NAME}
    ...    LOCATIONS=${LOCATIONS}
    ...    SLI_WINDOW_MINUTES=${SLI_WINDOW_MINUTES}
    ...    UTILIZATION_THRESHOLD_PERCENT=${UTILIZATION_THRESHOLD_PERCENT}
    ...    UNDERUTILIZATION_THRESHOLD_PERCENT=${UNDERUTILIZATION_THRESHOLD_PERCENT}
    ...    QUEUE_BACKLOG_THRESHOLD=${QUEUE_BACKLOG_THRESHOLD}
    ...    GOOGLE_APPLICATION_CREDENTIALS=./${gcp_credentials.key}
    ...    PATH=${OS_PATH}
    Set Suite Variable    ${env}    ${env_dict}
    RW.CLI.Run Cli
    ...    cmd=gcloud auth activate-service-account --key-file="./${gcp_credentials.key}" || true
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=60
    ...    include_in_history=false
