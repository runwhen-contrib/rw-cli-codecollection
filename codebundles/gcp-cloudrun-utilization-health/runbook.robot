*** Settings ***
Documentation       Monitors resource utilization and scaling configuration of GCP Cloud Run services, flagging over-provisioned (under-utilized), over-utilized, and improperly scaled services for cost and sizing review.
Metadata            Author    rw-codebundle-agent
Metadata            Display Name    GCP Cloud Run Utilization & Scaling Health
Metadata            Supports    GCP,Cloud Run,utilization,scaling

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             OperatingSystem
Library             Collections

Force Tags          GCP    CloudRun    Utilization    Scaling

Suite Setup         Suite Initialization

*** Tasks ***
Check Cloud Run Service CPU Utilization in GCP Project `${GCP_PROJECT_ID}`
    [Documentation]    Reads container CPU utilization for each Cloud Run service and flags services at or above the CPU threshold, indicating over-utilization and approaching capacity limits.
    [Tags]    gcloud    cloudrun    gcp    ${GCP_PROJECT_ID}    access:read-only    data:metrics
    ${cpu_result}=    RW.CLI.Run Bash File
    ...    bash_file=check_cpu_utilization.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./check_cpu_utilization.sh
    ${cpu_issues}=    RW.CLI.Run Cli
    ...    cmd=cat cpu_utilization_issues.json
    ...    env=${env}
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${cpu_issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for CPU utilization, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=${issue['expected']}
            ...    actual=${issue['actual']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${cpu_result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    Cloud Run CPU Utilization Analysis:\n${cpu_result.stdout}

Check Cloud Run Service Memory Utilization in GCP Project `${GCP_PROJECT_ID}`
    [Documentation]    Reads container memory utilization for each Cloud Run service and flags services at or above the memory threshold, indicating memory pressure and OOM risk.
    [Tags]    gcloud    cloudrun    gcp    ${GCP_PROJECT_ID}    access:read-only    data:metrics
    ${mem_result}=    RW.CLI.Run Bash File
    ...    bash_file=check_memory_utilization.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./check_memory_utilization.sh
    ${mem_issues}=    RW.CLI.Run Cli
    ...    cmd=cat memory_utilization_issues.json
    ...    env=${env}
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${mem_issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for memory utilization, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=${issue['expected']}
            ...    actual=${issue['actual']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${mem_result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    Cloud Run Memory Utilization Analysis:\n${mem_result.stdout}

Check Cloud Run Service Request Concurrency and Instance Scaling in GCP Project `${GCP_PROJECT_ID}`
    [Documentation]    Reviews target concurrency and instance scaling settings for each Cloud Run service, flagging unbounded max instances, very low concurrency targets, and min-instances settings that keep idle instances warm.
    [Tags]    gcloud    cloudrun    gcp    ${GCP_PROJECT_ID}    access:read-only    data:config
    ${scaling_result}=    RW.CLI.Run Bash File
    ...    bash_file=check_concurrency_scaling.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./check_concurrency_scaling.sh
    ${scaling_issues}=    RW.CLI.Run Cli
    ...    cmd=cat concurrency_scaling_issues.json
    ...    env=${env}
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${scaling_issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for concurrency/scaling, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=${issue['expected']}
            ...    actual=${issue['actual']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${scaling_result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    Cloud Run Concurrency & Scaling Analysis:\n${scaling_result.stdout}

Identify Under-Utilized Cloud Run Services in GCP Project `${GCP_PROJECT_ID}`
    [Documentation]    Identifies Cloud Run services with sustained near-zero utilization, surfacing over-provisioned or idle services that could be right-sized or scaled to zero.
    [Tags]    gcloud    cloudrun    gcp    ${GCP_PROJECT_ID}    access:read-only    data:metrics
    ${under_result}=    RW.CLI.Run Bash File
    ...    bash_file=find_underutilized_services.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./find_underutilized_services.sh
    ${under_issues}=    RW.CLI.Run Cli
    ...    cmd=cat underutilized_issues.json
    ...    env=${env}
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${under_issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for under-utilized services, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=${issue['expected']}
            ...    actual=${issue['actual']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${under_result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    Cloud Run Under-Utilized Service Analysis:\n${under_result.stdout}

Report Cloud Run Utilization and Scaling Configuration for GCP Project `${GCP_PROJECT_ID}`
    [Documentation]    Captures utilization metrics and scaling configuration for all Cloud Run services into the report to enable LLM-based cost and sizing review.
    [Tags]    gcloud    cloudrun    gcp    ${GCP_PROJECT_ID}    access:read-only    data:metrics-config
    ${report_result}=    RW.CLI.Run Bash File
    ...    bash_file=capture_utilization_report.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./capture_utilization_report.sh
    ${report_json}=    RW.CLI.Run Cli
    ...    cmd=cat utilization_report.json
    ...    env=${env}
    RW.Core.Add Pre To Report    Cloud Run Utilization & Scaling Report:\n${report_json.stdout}

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
    ${MIN_UTILIZATION_THRESHOLD}=    RW.Core.Import User Variable    MIN_UTILIZATION_THRESHOLD
    ...    type=string
    ...    description=Low utilization percentage threshold below which a service is considered under-utilized.
    ...    pattern=^\d+$
    ...    default=10
    ${OS_PATH}=    Get Environment Variable    PATH
    Set Suite Variable    ${GCP_PROJECT_ID}    ${GCP_PROJECT_ID}
    Set Suite Variable    ${gcp_credentials}    ${gcp_credentials}
    Set Suite Variable    ${RESOURCES}    ${RESOURCES}
    Set Suite Variable    ${METRIC_LOOKBACK_PERIOD}    ${METRIC_LOOKBACK_PERIOD}
    Set Suite Variable    ${CPU_UTILIZATION_THRESHOLD}    ${CPU_UTILIZATION_THRESHOLD}
    Set Suite Variable    ${MEMORY_UTILIZATION_THRESHOLD}    ${MEMORY_UTILIZATION_THRESHOLD}
    Set Suite Variable    ${MIN_UTILIZATION_THRESHOLD}    ${MIN_UTILIZATION_THRESHOLD}
    ${env}=    Create Dictionary
    ...    CLOUDSDK_CORE_PROJECT=${GCP_PROJECT_ID}
    ...    PATH=$PATH:${OS_PATH}
    ...    GCP_PROJECT_ID=${GCP_PROJECT_ID}
    ...    RESOURCES=${RESOURCES}
    ...    METRIC_LOOKBACK_PERIOD=${METRIC_LOOKBACK_PERIOD}
    ...    CPU_UTILIZATION_THRESHOLD=${CPU_UTILIZATION_THRESHOLD}
    ...    MEMORY_UTILIZATION_THRESHOLD=${MEMORY_UTILIZATION_THRESHOLD}
    ...    MIN_UTILIZATION_THRESHOLD=${MIN_UTILIZATION_THRESHOLD}
    Set Suite Variable    ${env}    ${env}
    RW.CLI.Run CLI
    ...    cmd=gcloud auth activate-service-account --key-file="./${gcp_credentials.key}" || true
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
