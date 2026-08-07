*** Settings ***
Documentation       Monitor the runtime traffic, performance, and reliability of Apigee API proxying via Cloud Monitoring, flagging elevated error/fault rates, high latency percentiles, throughput anomalies, and degraded target/backend behavior.
Metadata            Author    rw-codebundle-agent
Metadata            Display Name    GCP Apigee Traffic and Performance Health
Metadata            Supports    GCP,Apigee,API Management,Traffic Monitoring
Force Tags          GCP    Apigee    API Management    Traffic Monitoring

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             OperatingSystem
Library             Collections

Suite Setup         Suite Initialization

*** Tasks ***
Discover Apigee Proxies and Environments for Metrics in `${APIGEE_ORG}`
    [Documentation]    Enumerates API proxies, environments, and target servers at org scope to scope the metric checks and map proxy/environment labels for the Cloud Monitoring queries.
    [Tags]    gcloud    apigee    gcp    ${APIGEE_ORG}    access:read-only    data:config
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=discover_metrics_scope.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./discover_metrics_scope.sh
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat discovery_issues.json
    ...    env=${env}
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for Apigee discovery, defaulting to empty list.    WARN
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
    RW.Core.Add Pre To Report    Apigee Metrics Scope Discovery:\n${result.stdout}

Check Apigee API Error and Fault Rates in `${GCP_PROJECT_ID}`
    [Documentation]    Queries proxy-level proxyv2 request/response counts and server fault_count metrics over the window to compute error/fault rates, flagging proxies whose 4xx/5xx or fault rate exceeds ERROR_RATE_THRESHOLD.
    [Tags]    gcloud    apigee    monitoring    gcp    ${GCP_PROJECT_ID}    access:read-only    data:metrics
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check_error_rates.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./check_error_rates.sh
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat error_rate_issues.json
    ...    env=${env}
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for error rates, defaulting to empty list.    WARN
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
    RW.Core.Add Pre To Report    Apigee Error and Fault Rate Analysis:\n${result.stdout}

Check Apigee API Latency Performance in `${GCP_PROJECT_ID}`
    [Documentation]    Queries proxyv2/percentile latency metrics (p50/p90/p99) and flags proxies whose p95/p99 latency exceeds LATENCY_MS_THRESHOLD, indicating slow APIs.
    [Tags]    gcloud    apigee    monitoring    gcp    ${GCP_PROJECT_ID}    access:read-only    data:metrics
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check_latency.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./check_latency.sh
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat latency_issues.json
    ...    env=${env}
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for latency, defaulting to empty list.    WARN
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
    RW.Core.Add Pre To Report    Apigee Latency Performance Analysis:\n${result.stdout}

Check Apigee Throughput and Anomalies in `${GCP_PROJECT_ID}`
    [Documentation]    Reviews request/response volume and the environment/anomaly_count metric, flagging anomalous traffic (spikes or drops) that may indicate an incident, a mis-route, or a dead backend.
    [Tags]    gcloud    apigee    monitoring    gcp    ${GCP_PROJECT_ID}    access:read-only    data:metrics
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check_throughput.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./check_throughput.sh
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat throughput_issues.json
    ...    env=${env}
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for throughput and anomalies, defaulting to empty list.    WARN
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
    RW.Core.Add Pre To Report    Apigee Throughput and Anomaly Analysis:\n${result.stdout}

Check Apigee Target and Backend Performance in `${GCP_PROJECT_ID}`
    [Documentation]    Queries target/upstream request, response, and latency metrics to detect slow or failing backend target servers, flagging targets with elevated latency or errors.
    [Tags]    gcloud    apigee    monitoring    gcp    ${GCP_PROJECT_ID}    access:read-only    data:metrics
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check_target_performance.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./check_target_performance.sh
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat target_performance_issues.json
    ...    env=${env}
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for target performance, defaulting to empty list.    WARN
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
    RW.Core.Add Pre To Report    Apigee Target and Backend Performance Analysis:\n${result.stdout}

Generate Apigee Traffic Health Summary for `${APIGEE_ORG}`
    [Documentation]    Aggregates error, latency, throughput, and target findings into a consolidated traffic health summary (worst proxies by error rate and latency, anomaly count, overall verdict).
    [Tags]    gcloud    apigee    gcp    ${APIGEE_ORG}    access:read-only    data:metrics
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=generate_traffic_summary.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./generate_traffic_summary.sh
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat traffic_summary_issues.json
    ...    env=${env}
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for traffic summary, defaulting to empty list.    WARN
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
    RW.Core.Add Pre To Report    Apigee Traffic Health Summary:\n${result.stdout}

*** Keywords ***
Suite Initialization
    ${gcp_credentials}=    RW.Core.Import Secret    gcp_credentials
    ...    type=string
    ...    description=GCP service account json used to authenticate with GCP APIs and Cloud Monitoring.
    ...    pattern=\w*
    ...    example={"type": "service_account","project_id":"myproject-ID", ... super secret stuff ...}
    ${APIGEE_ORG}=    RW.Core.Import User Variable    APIGEE_ORG
    ...    type=string
    ...    description=The Apigee organization name that scopes which proxies, environments, and target servers are evaluated.
    ...    pattern=\w*
    ...    example=my-apigee-org
    ${GCP_PROJECT_ID}=    RW.Core.Import User Variable    GCP_PROJECT_ID
    ...    type=string
    ...    description=The GCP Project ID that hosts the Apigee runtime and is the Cloud Monitoring scope for metric queries.
    ...    pattern=\w*
    ...    example=myproject-ID
    ${ERROR_RATE_THRESHOLD}=    RW.Core.Import User Variable    ERROR_RATE_THRESHOLD
    ...    type=string
    ...    description=Error/fault rate (percent of requests returning 4xx/5xx or faults) above which a proxy is flagged.
    ...    pattern=^\d*\.?\d+$
    ...    default=5
    ${LATENCY_MS_THRESHOLD}=    RW.Core.Import User Variable    LATENCY_MS_THRESHOLD
    ...    type=string
    ...    description=p95 latency in milliseconds above which a proxy is flagged as slow.
    ...    pattern=^\d+$
    ...    default=500
    ${METRIC_WINDOW_MIN}=    RW.Core.Import User Variable    METRIC_WINDOW_MIN
    ...    type=string
    ...    description=Lookback window in minutes for the Cloud Monitoring metric queries.
    ...    pattern=^\d+$
    ...    default=60
    Set Suite Variable    ${gcp_credentials}    ${gcp_credentials}
    Set Suite Variable    ${APIGEE_ORG}    ${APIGEE_ORG}
    Set Suite Variable    ${GCP_PROJECT_ID}    ${GCP_PROJECT_ID}
    Set Suite Variable    ${ERROR_RATE_THRESHOLD}    ${ERROR_RATE_THRESHOLD}
    Set Suite Variable    ${LATENCY_MS_THRESHOLD}    ${LATENCY_MS_THRESHOLD}
    Set Suite Variable    ${METRIC_WINDOW_MIN}    ${METRIC_WINDOW_MIN}
    ${OS_PATH}=    Get Environment Variable    PATH
    Set Suite Variable
    ...    ${env}
    ...    {"CLOUDSDK_CORE_PROJECT":"${GCP_PROJECT_ID}","PATH":"$PATH:${OS_PATH}","APIGEE_ORG":"${APIGEE_ORG}","GCP_PROJECT_ID":"${GCP_PROJECT_ID}","ERROR_RATE_THRESHOLD":"${ERROR_RATE_THRESHOLD}","LATENCY_MS_THRESHOLD":"${LATENCY_MS_THRESHOLD}","METRIC_WINDOW_MIN":"${METRIC_WINDOW_MIN}"}
    RW.CLI.Run CLI
    ...    cmd=gcloud auth activate-service-account --key-file="./${gcp_credentials.key}" || true
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
