*** Settings ***
Documentation       Diagnose GCP API Gateway health and the gateway-to-backend edge, distinguishing gateway faults from faults in the Cloud Run backends behind them
Metadata            Author    rw-codebundle-agent
Metadata            Display Name    GCP API Gateway Health
Metadata            Supports    GCP,API Gateway,Cloud Run
Force Tags          GCP    API Gateway    Cloud Run

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             OperatingSystem
Library             Collections

Suite Setup         Suite Initialization

*** Tasks ***
Discover GCP API Gateway Apis, Configs and Gateways in `${GCP_PROJECT_ID}`
    [Documentation]    Lists all Api, ApiConfig and Gateway resources in the project plus their states using the gcloud api-gateway CLI, and dumps a JSON inventory consumed by the other tasks.
    [Tags]    gcloud    apigateway    gcp    ${GCP_PROJECT_ID}    access:read-only    data:config
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=discover_apigateway.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./discover_apigateway.sh
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat apigateway_discovery_issues.json
    ...    env=${env}
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for discovery, defaulting to empty list.    WARN
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
    RW.Core.Add Pre To Report    API Gateway Discovery:\n${result.stdout}

Check GCP API Gateway Resource States in `${GCP_PROJECT_ID}`
    [Documentation]    Flags any Api, ApiConfig or Gateway in a FAILED (or otherwise non-ACTIVE critical) state, which indicates a broken deployment that never took effect.
    [Tags]    gcloud    apigateway    state    gcp    ${GCP_PROJECT_ID}    access:read-only    data:state
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check_states.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./check_states.sh
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat resource_state_issues.json
    ...    env=${env}
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for resource states, defaulting to empty list.    WARN
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
    RW.Core.Add Pre To Report    API Gateway Resource State Analysis:\n${result.stdout}

Check GCP API Gateway Config Drift in `${GCP_PROJECT_ID}`
    [Documentation]    For each Gateway, verifies gateway.apiConfig points at the newest ACTIVE ApiConfig for its API, flagging silent drift where stale routes are served in production.
    [Tags]    gcloud    apigateway    config    gcp    ${GCP_PROJECT_ID}    access:read-only    data:config
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check_config_drift.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./check_config_drift.sh
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat config_drift_issues.json
    ...    env=${env}
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for config drift, defaulting to empty list.    WARN
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
    RW.Core.Add Pre To Report    API Gateway Config Drift Analysis:\n${result.stdout}

Verify API Gateway Managed Service is Enabled in `${GCP_PROJECT_ID}`
    [Documentation]    Confirms the API's managed Service Infrastructure service (named <api-id>-<hash>.apigateway.<project>.cloud.goog) is enabled on the project, flagging an 'API not enabled' total outage at the edge.
    [Tags]    gcloud    apigateway    services    gcp    ${GCP_PROJECT_ID}    access:read-only    data:config
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check_managed_service.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./check_managed_service.sh
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat managed_service_issues.json
    ...    env=${env}
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for managed service, defaulting to empty list.    WARN
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
    RW.Core.Add Pre To Report    API Gateway Managed Service Analysis:\n${result.stdout}

Check Gateway Backend Invoker Permissions in `${GCP_PROJECT_ID}`
    [Documentation]    For the deployed ApiConfig of each gateway, verifies the gateway service account holds roles/run.invoker on every Cloud Run backend it calls, flagging the most common 403 failure mode.
    [Tags]    gcloud    apigateway    run    iam    gcp    ${GCP_PROJECT_ID}    access:read-only    data:config
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check_invoker_binding.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./check_invoker_binding.sh
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat invoker_binding_issues.json
    ...    env=${env}
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for invoker bindings, defaulting to empty list.    WARN
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
    RW.Core.Add Pre To Report    API Gateway Invoker Binding Analysis:\n${result.stdout}

Detect Dangling and Unreachable Gateway Backends in `${GCP_PROJECT_ID}`
    [Documentation]    Flags backends referenced by x-google-backend.address that no longer exist (dangling route) and surfaces 504s where backend latency nears the ESPv2 deadline, handing off backend evidence to the Cloud Run bundle.
    [Tags]    gcloud    apigateway    run    gcp    ${GCP_PROJECT_ID}    access:read-only    data:logs-config
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check_backends.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./check_backends.sh
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat backend_issues.json
    ...    env=${env}
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for backends, defaulting to empty list.    WARN
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
    RW.Core.Add Pre To Report    API Gateway Backend Analysis:\n${result.stdout}

Analyze GCP API Gateway Error Rates in `${GCP_PROJECT_ID}`
    [Documentation]    Queries Cloud Monitoring for gateway request error rates, flagging 5xx rate above ERROR_RATE_THRESHOLD and a tighter 401/403 rate above AUTH_ERROR_RATE_THRESHOLD.
    [Tags]    gcloud    apigateway    monitoring    gcp    ${GCP_PROJECT_ID}    access:read-only    data:metrics
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
    RW.Core.Add Pre To Report    API Gateway Error Rate Analysis:\n${result.stdout}

Analyze GCP API Gateway Latency in `${GCP_PROJECT_ID}`
    [Documentation]    Queries Cloud Monitoring for p95 gateway latency, flagging values above LATENCY_THRESHOLD_MS and a large gap between total gateway and backend latency that isolates gateway (ESPv2) overhead.
    [Tags]    gcloud    apigateway    monitoring    gcp    ${GCP_PROJECT_ID}    access:read-only    data:metrics
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
    RW.Core.Add Pre To Report    API Gateway Latency Analysis:\n${result.stdout}

Check for Failed GCP API Gateway Operations in `${GCP_PROJECT_ID}`
    [Documentation]    Lists API Gateway operations in the region(s) within OPERATIONS_LOOKBACK and flags any operation in a FAILED state, indicating a provisioning or update that did not take effect.
    [Tags]    gcloud    apigateway    operations    gcp    ${GCP_PROJECT_ID}    access:read-only    data:logs-config
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check_operations.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./check_operations.sh
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat operations_issues.json
    ...    env=${env}
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for operations, defaulting to empty list.    WARN
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
    RW.Core.Add Pre To Report    API Gateway Operations Analysis:\n${result.stdout}

Generate GCP API Gateway Health Summary for `${GCP_PROJECT_ID}`
    [Documentation]    Aggregates findings from all other checks into a consolidated per-gateway summary with an overall verdict, reporting an informational single-region (no-failover) advisory.
    [Tags]    gcloud    apigateway    gcp    ${GCP_PROJECT_ID}    access:read-only    data:state
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=generate_summary.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./generate_summary.sh
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat summary_issues.json
    ...    env=${env}
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for summary, defaulting to empty list.    WARN
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
    RW.Core.Add Pre To Report    API Gateway Health Summary:\n${result.stdout}

*** Keywords ***
Suite Initialization
    ${gcp_credentials}=    RW.Core.Import Secret    gcp_credentials
    ...    type=string
    ...    description=GCP service account json used to authenticate with GCP APIs.
    ...    pattern=\w*
    ...    example={"type": "service_account","project_id":"myproject-ID", ... super secret stuff ...}
    ${GCP_PROJECT_ID}=    RW.Core.Import User Variable    GCP_PROJECT_ID
    ...    type=string
    ...    description=The GCP Project ID that hosts the API Gateways to check.
    ...    pattern=\w*
    ...    example=myproject-ID
    ${GCP_REGIONS}=    RW.Core.Import User Variable    GCP_REGIONS
    ...    type=string
    ...    description=Comma-separated list of regions to search for regional Gateways and operations. Empty means discover regions dynamically from the Gateway list.
    ...    pattern=\w*
    ...    default=
    ${API_NAME}=    RW.Core.Import User Variable    API_NAME
    ...    type=string
    ...    description=Optional: restrict to a single API id. Empty means all APIs.
    ...    pattern=\w*
    ...    default=
    ${API_CONFIG_NAME}=    RW.Core.Import User Variable    API_CONFIG_NAME
    ...    type=string
    ...    description=Optional: restrict to a single ApiConfig. Empty means all.
    ...    pattern=\w*
    ...    default=
    ${METRIC_LOOKBACK_PERIOD}=    RW.Core.Import User Variable    METRIC_LOOKBACK_PERIOD
    ...    type=string
    ...    description=Cloud Monitoring lookback period for metric queries (seconds, e.g. 3600s).
    ...    pattern=^\d+s$
    ...    default=3600s
    ${ERROR_RATE_THRESHOLD}=    RW.Core.Import User Variable    ERROR_RATE_THRESHOLD
    ...    type=string
    ...    description=Maximum acceptable 5xx error ratio (0.01 = 1%).
    ...    pattern=^\d*\.?\d+$
    ...    default=0.01
    ${AUTH_ERROR_RATE_THRESHOLD}=    RW.Core.Import User Variable    AUTH_ERROR_RATE_THRESHOLD
    ...    type=string
    ...    description=Tighter maximum acceptable 401/403 ratio (0.005 = 0.5%).
    ...    pattern=^\d*\.?\d+$
    ...    default=0.005
    ${LATENCY_THRESHOLD_MS}=    RW.Core.Import User Variable    LATENCY_THRESHOLD_MS
    ...    type=string
    ...    description=Maximum acceptable p95 gateway latency in milliseconds.
    ...    pattern=^\d+$
    ...    default=5000
    ${LATENCY_GAP_THRESHOLD_MS}=    RW.Core.Import User Variable    LATENCY_GAP_THRESHOLD_MS
    ...    type=string
    ...    description=Maximum acceptable gateway-vs-backend latency gap in milliseconds.
    ...    pattern=^\d+$
    ...    default=1000
    ${OPERATIONS_LOOKBACK}=    RW.Core.Import User Variable    OPERATIONS_LOOKBACK
    ...    type=string
    ...    description=Lookback window for failed operations (e.g. 1h or 24h).
    ...    pattern=\w*
    ...    default=24h
    ${ENABLE_SINGLE_REGION_ADVISORY}=    RW.Core.Import User Variable    ENABLE_SINGLE_REGION_ADVISORY
    ...    type=string
    ...    description=Set true to emit informational single-region (no-failover) findings.
    ...    pattern=\w*
    ...    default=true
    ${METRIC_TYPE_OVERRIDE}=    RW.Core.Import User Variable    METRIC_TYPE_OVERRIDE
    ...    type=string
    ...    description=Optional override for the request-count metric type used by the error/backend checks. Leave empty to resolve at runtime.
    ...    pattern=\w*
    ...    default=
    Set Suite Variable    ${GCP_PROJECT_ID}    ${GCP_PROJECT_ID}
    Set Suite Variable    ${gcp_credentials}    ${gcp_credentials}
    Set Suite Variable    ${GCP_REGIONS}    ${GCP_REGIONS}
    Set Suite Variable    ${API_NAME}    ${API_NAME}
    Set Suite Variable    ${API_CONFIG_NAME}    ${API_CONFIG_NAME}
    Set Suite Variable    ${METRIC_LOOKBACK_PERIOD}    ${METRIC_LOOKBACK_PERIOD}
    Set Suite Variable    ${ERROR_RATE_THRESHOLD}    ${ERROR_RATE_THRESHOLD}
    Set Suite Variable    ${AUTH_ERROR_RATE_THRESHOLD}    ${AUTH_ERROR_RATE_THRESHOLD}
    Set Suite Variable    ${LATENCY_THRESHOLD_MS}    ${LATENCY_THRESHOLD_MS}
    Set Suite Variable    ${LATENCY_GAP_THRESHOLD_MS}    ${LATENCY_GAP_THRESHOLD_MS}
    Set Suite Variable    ${OPERATIONS_LOOKBACK}    ${OPERATIONS_LOOKBACK}
    Set Suite Variable    ${ENABLE_SINGLE_REGION_ADVISORY}    ${ENABLE_SINGLE_REGION_ADVISORY}
    Set Suite Variable    ${METRIC_TYPE_OVERRIDE}    ${METRIC_TYPE_OVERRIDE}
    ${OS_PATH}=    Get Environment Variable    PATH
    Set Suite Variable
    ...    ${env}
    ...    {"CLOUDSDK_CORE_PROJECT":"${GCP_PROJECT_ID}","PATH":"$PATH:${OS_PATH}","GCP_PROJECT_ID":"${GCP_PROJECT_ID}","GCP_REGIONS":"${GCP_REGIONS}","API_NAME":"${API_NAME}","API_CONFIG_NAME":"${API_CONFIG_NAME}","METRIC_LOOKBACK_PERIOD":"${METRIC_LOOKBACK_PERIOD}","ERROR_RATE_THRESHOLD":"${ERROR_RATE_THRESHOLD}","AUTH_ERROR_RATE_THRESHOLD":"${AUTH_ERROR_RATE_THRESHOLD}","LATENCY_THRESHOLD_MS":"${LATENCY_THRESHOLD_MS}","LATENCY_GAP_THRESHOLD_MS":"${LATENCY_GAP_THRESHOLD_MS}","OPERATIONS_LOOKBACK":"${OPERATIONS_LOOKBACK}","ENABLE_SINGLE_REGION_ADVISORY":"${ENABLE_SINGLE_REGION_ADVISORY}","METRIC_TYPE_OVERRIDE":"${METRIC_TYPE_OVERRIDE}"}
    RW.CLI.Run CLI
    ...    cmd=gcloud auth activate-service-account --key-file="./${gcp_credentials.key}" || true
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
