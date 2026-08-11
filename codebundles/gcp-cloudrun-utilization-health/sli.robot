*** Settings ***
Documentation       Scores GCP Cloud Run utilization and scaling health as a binary value: 1 only if every health dimension passes (no over-utilized CPU, no memory OOM risk, no dangerous scaling configuration), 0 if any dimension is degraded.
Metadata            Author    rw-codebundle-agent
Metadata            Display Name    GCP Cloud Run Utilization & Scaling Health
Metadata            Supports    GCP,Cloud Run

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             OperatingSystem

Suite Setup         Suite Initialization

*** Tasks ***
Score Cloud Run Service CPU Utilization in GCP Project `${GCP_PROJECT_ID}`
    [Documentation]    Scores 1 if no Cloud Run service has CPU utilization at or above the CPU threshold, 0 otherwise.
    [Tags]    gcloud    cloudrun    gcp    ${GCP_PROJECT_ID}    access:read-only    data:metrics
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check_cpu_utilization.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ${issues_output}=    RW.CLI.Run Cli
    ...    cmd=cat cpu_utilization_issues.json | jq length
    ...    env=${env}
    ${cpu_score}=    Evaluate    1 if int(${issues_output.stdout}) == 0 else 0
    Set Suite Variable    ${cpu_score}
    RW.Core.Push Metric    ${issues_output.stdout}    sub_name=over_utilized_cpu_count
    RW.Core.Push Metric    ${cpu_score}    sub_name=cpu_utilization

Score Cloud Run Service Memory Utilization in GCP Project `${GCP_PROJECT_ID}`
    [Documentation]    Scores 1 if no Cloud Run service has memory utilization at or above the memory threshold (OOM risk), 0 otherwise.
    [Tags]    gcloud    cloudrun    gcp    ${GCP_PROJECT_ID}    access:read-only    data:metrics
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check_memory_utilization.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ${issues_output}=    RW.CLI.Run Cli
    ...    cmd=cat memory_utilization_issues.json | jq length
    ...    env=${env}
    ${mem_score}=    Evaluate    1 if int(${issues_output.stdout}) == 0 else 0
    Set Suite Variable    ${mem_score}
    RW.Core.Push Metric    ${issues_output.stdout}    sub_name=oom_risk_service_count
    RW.Core.Push Metric    ${mem_score}    sub_name=memory_utilization

Score Cloud Run Service Scaling Configuration in GCP Project `${GCP_PROJECT_ID}`
    [Documentation]    Scores 1 if no Cloud Run service has unbounded max instances, very low concurrency, or min-instances keeping idle instances warm, 0 otherwise.
    [Tags]    gcloud    cloudrun    gcp    ${GCP_PROJECT_ID}    access:read-only    data:config
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check_concurrency_scaling.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ${issues_output}=    RW.CLI.Run Cli
    ...    cmd=cat concurrency_scaling_issues.json | jq length
    ...    env=${env}
    ${scaling_score}=    Evaluate    1 if int(${issues_output.stdout}) == 0 else 0
    Set Suite Variable    ${scaling_score}
    RW.Core.Push Metric    ${issues_output.stdout}    sub_name=scaling_issue_count
    RW.Core.Push Metric    ${scaling_score}    sub_name=scaling_configuration

Generate Aggregate Cloud Run Utilization Health Score for `${GCP_PROJECT_ID}`
    [Documentation]    Overall score is 1 only if every utilization/scaling dimension passes; 0 if any dimension is degraded.
    [Tags]    gcloud    cloudrun    gcp    ${GCP_PROJECT_ID}    access:read-only    data:metrics
    ${health_score}=    Evaluate    1 if (${cpu_score} + ${mem_score} + ${scaling_score}) == 3 else 0
    RW.Core.Add to Report    Cloud Run Utilization & Scaling Health Score: ${health_score} -- cpu: ${cpu_score}, memory: ${mem_score}, scaling: ${scaling_score}
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
    ...    description=The GCP Project ID to scope the API to.
    ...    pattern=\w*
    ...    example=myproject-ID
    ${RESOURCES}=    RW.Core.Import User Variable    RESOURCES
    ...    type=string
    ...    description=Comma-separated Cloud Run service names to check, or 'All' to auto-discover all services in the project.
    ...    pattern=\w*
    ...    default=All
    ${METRIC_LOOKBACK_PERIOD}=    RW.Core.Import User Variable    METRIC_LOOKBACK_PERIOD
    ...    type=string
    ...    description=Lookback window for monitoring metrics, e.g. '3600s'.
    ...    pattern=\w*
    ...    default=3600s
    ${CPU_UTILIZATION_THRESHOLD}=    RW.Core.Import User Variable    CPU_UTILIZATION_THRESHOLD
    ...    type=string
    ...    description=High CPU utilization percentage threshold above which a service is flagged as over-utilized.
    ...    pattern=^\d+$
    ...    default=80
    ${MEMORY_UTILIZATION_THRESHOLD}=    RW.Core.Import User Variable    MEMORY_UTILIZATION_THRESHOLD
    ...    type=string
    ...    description=High memory utilization percentage threshold above which a service is flagged for OOM risk.
    ...    pattern=^\d+$
    ...    default=85
    ${OS_PATH}=    Get Environment Variable    PATH
    Set Suite Variable    ${GCP_PROJECT_ID}    ${GCP_PROJECT_ID}
    Set Suite Variable    ${gcp_credentials}    ${gcp_credentials}
    Set Suite Variable    ${RESOURCES}    ${RESOURCES}
    Set Suite Variable    ${METRIC_LOOKBACK_PERIOD}    ${METRIC_LOOKBACK_PERIOD}
    Set Suite Variable    ${CPU_UTILIZATION_THRESHOLD}    ${CPU_UTILIZATION_THRESHOLD}
    Set Suite Variable    ${MEMORY_UTILIZATION_THRESHOLD}    ${MEMORY_UTILIZATION_THRESHOLD}
    ${env}=    Create Dictionary
    ...    CLOUDSDK_CORE_PROJECT=${GCP_PROJECT_ID}
    ...    PATH=$PATH:${OS_PATH}
    ...    GCP_PROJECT_ID=${GCP_PROJECT_ID}
    ...    RESOURCES=${RESOURCES}
    ...    METRIC_LOOKBACK_PERIOD=${METRIC_LOOKBACK_PERIOD}
    ...    CPU_UTILIZATION_THRESHOLD=${CPU_UTILIZATION_THRESHOLD}
    ...    MEMORY_UTILIZATION_THRESHOLD=${MEMORY_UTILIZATION_THRESHOLD}
    Set Suite Variable    ${env}    ${env}
    RW.CLI.Run CLI
    ...    cmd=gcloud auth activate-service-account --key-file="./${gcp_credentials.key}" || true
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
