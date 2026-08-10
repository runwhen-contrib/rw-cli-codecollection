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
Check GCP API Gateway Resource States in `${GCP_PROJECT_ID}`
    [Documentation]    Flags any Api, ApiConfig or Gateway in a FAILED (or otherwise non-ACTIVE critical) state, which indicates a broken deployment that never took effect.
    [Tags]    gcloud    apigateway    state    gcp    ${GCP_PROJECT_ID}    access:read-only    data:state
    # Remove any output from a previous run first. The working directory is
    # reused between runs, so a stale file would otherwise be read as this
    # run's result even when the check below never writes one.
    RW.CLI.Run Cli
    ...    cmd=rm -f resource_state_issues.json
    ...    env=${env}
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check_states.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./check_states.sh
    IF    $result.returncode != 0
        Fail    check_states.sh exited ${result.returncode}. The check did not complete, so any output present is stale from an earlier run. Refusing to report a result for a check that failed.
    END
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat resource_state_issues.json
    ...    env=${env}
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT    AS    ${parse_error}
        Fail    The resource states check did not produce a parseable issues file (${parse_error}). The check script failed - see the task output above. Refusing to report "no issues" for a check that never ran.
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
    # Remove any output from a previous run first. The working directory is
    # reused between runs, so a stale file would otherwise be read as this
    # run's result even when the check below never writes one.
    RW.CLI.Run Cli
    ...    cmd=rm -f config_drift_issues.json
    ...    env=${env}
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check_config_drift.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./check_config_drift.sh
    IF    $result.returncode != 0
        Fail    check_config_drift.sh exited ${result.returncode}. The check did not complete, so any output present is stale from an earlier run. Refusing to report a result for a check that failed.
    END
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat config_drift_issues.json
    ...    env=${env}
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT    AS    ${parse_error}
        Fail    The config drift check did not produce a parseable issues file (${parse_error}). The check script failed - see the task output above. Refusing to report "no issues" for a check that never ran.
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
    # Remove any output from a previous run first. The working directory is
    # reused between runs, so a stale file would otherwise be read as this
    # run's result even when the check below never writes one.
    RW.CLI.Run Cli
    ...    cmd=rm -f managed_service_issues.json
    ...    env=${env}
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check_managed_service.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./check_managed_service.sh
    IF    $result.returncode != 0
        Fail    check_managed_service.sh exited ${result.returncode}. The check did not complete, so any output present is stale from an earlier run. Refusing to report a result for a check that failed.
    END
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat managed_service_issues.json
    ...    env=${env}
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT    AS    ${parse_error}
        Fail    The managed service check did not produce a parseable issues file (${parse_error}). The check script failed - see the task output above. Refusing to report "no issues" for a check that never ran.
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
    # Remove any output from a previous run first. The working directory is
    # reused between runs, so a stale file would otherwise be read as this
    # run's result even when the check below never writes one.
    RW.CLI.Run Cli
    ...    cmd=rm -f invoker_binding_issues.json
    ...    env=${env}
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check_invoker_binding.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./check_invoker_binding.sh
    IF    $result.returncode != 0
        Fail    check_invoker_binding.sh exited ${result.returncode}. The check did not complete, so any output present is stale from an earlier run. Refusing to report a result for a check that failed.
    END
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat invoker_binding_issues.json
    ...    env=${env}
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT    AS    ${parse_error}
        Fail    The invoker bindings check did not produce a parseable issues file (${parse_error}). The check script failed - see the task output above. Refusing to report "no issues" for a check that never ran.
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
    # Remove any output from a previous run first. The working directory is
    # reused between runs, so a stale file would otherwise be read as this
    # run's result even when the check below never writes one.
    RW.CLI.Run Cli
    ...    cmd=rm -f backend_issues.json
    ...    env=${env}
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check_backends.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./check_backends.sh
    IF    $result.returncode != 0
        Fail    check_backends.sh exited ${result.returncode}. The check did not complete, so any output present is stale from an earlier run. Refusing to report a result for a check that failed.
    END
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat backend_issues.json
    ...    env=${env}
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT    AS    ${parse_error}
        Fail    The backends check did not produce a parseable issues file (${parse_error}). The check script failed - see the task output above. Refusing to report "no issues" for a check that never ran.
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
    # Remove any output from a previous run first. The working directory is
    # reused between runs, so a stale file would otherwise be read as this
    # run's result even when the check below never writes one.
    RW.CLI.Run Cli
    ...    cmd=rm -f error_rate_issues.json
    ...    env=${env}
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check_error_rates.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./check_error_rates.sh
    IF    $result.returncode != 0
        Fail    check_error_rates.sh exited ${result.returncode}. The check did not complete, so any output present is stale from an earlier run. Refusing to report a result for a check that failed.
    END
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat error_rate_issues.json
    ...    env=${env}
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT    AS    ${parse_error}
        Fail    The error rates check did not produce a parseable issues file (${parse_error}). The check script failed - see the task output above. Refusing to report "no issues" for a check that never ran.
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
    # Remove any output from a previous run first. The working directory is
    # reused between runs, so a stale file would otherwise be read as this
    # run's result even when the check below never writes one.
    RW.CLI.Run Cli
    ...    cmd=rm -f latency_issues.json
    ...    env=${env}
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check_latency.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./check_latency.sh
    IF    $result.returncode != 0
        Fail    check_latency.sh exited ${result.returncode}. The check did not complete, so any output present is stale from an earlier run. Refusing to report a result for a check that failed.
    END
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat latency_issues.json
    ...    env=${env}
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT    AS    ${parse_error}
        Fail    The latency check did not produce a parseable issues file (${parse_error}). The check script failed - see the task output above. Refusing to report "no issues" for a check that never ran.
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
    # Remove any output from a previous run first. The working directory is
    # reused between runs, so a stale file would otherwise be read as this
    # run's result even when the check below never writes one.
    RW.CLI.Run Cli
    ...    cmd=rm -f operations_issues.json
    ...    env=${env}
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check_operations.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./check_operations.sh
    IF    $result.returncode != 0
        Fail    check_operations.sh exited ${result.returncode}. The check did not complete, so any output present is stale from an earlier run. Refusing to report a result for a check that failed.
    END
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat operations_issues.json
    ...    env=${env}
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT    AS    ${parse_error}
        Fail    The operations check did not produce a parseable issues file (${parse_error}). The check script failed - see the task output above. Refusing to report "no issues" for a check that never ran.
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
    # Remove any output from a previous run first. The working directory is
    # reused between runs, so a stale file would otherwise be read as this
    # run's result even when the check below never writes one.
    RW.CLI.Run Cli
    ...    cmd=rm -f summary_issues.json apigateway_summary_table.txt
    ...    env=${env}
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=generate_summary.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./generate_summary.sh
    IF    $result.returncode != 0
        Fail    generate_summary.sh exited ${result.returncode}. The check did not complete, so any output present is stale from an earlier run. Refusing to report a result for a check that failed.
    END
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat summary_issues.json
    ...    env=${env}
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT    AS    ${parse_error}
        Fail    The summary check did not produce a parseable issues file (${parse_error}). The check script failed - see the task output above. Refusing to report "no issues" for a check that never ran.
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
    # Discovery runs in suite setup rather than as a task, so its inventory
    # counts are surfaced here alongside the summary they describe.
    RW.Core.Add Pre To Report    API Gateway Discovery:\n${discovery.stdout}
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
    # Discovery runs here rather than as a task. It writes the inventory every
    # task below reads, but it can never raise an issue -- it always writes an
    # empty issues file -- so as a task it occupied a slot in the operator's
    # list while being incapable of reporting anything.
    #
    # Running it as setup also improves the failure it now produces: a disabled
    # API used to surface as ten red tasks (discovery, then nine dependants
    # failing on the missing inventory). As setup it is one failure naming the
    # actual cause, and the rest are not attempted.
    #
    # sli.robot already did this, for the same reason.
    RW.CLI.Run Cli
    ...    cmd=rm -f apigateway_inventory.json apigateway_discovery_issues.json
    ...    env=${env}
    ${discovery}=    RW.CLI.Run Bash File
    ...    bash_file=discover_apigateway.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./discover_apigateway.sh
    IF    $discovery.returncode != 0
        Fail    discover_apigateway.sh exited ${discovery.returncode}. No inventory was produced, so no check below can run. See the output above for the cause -- a disabled API Gateway API is the most common one.
    END
    Set Suite Variable    ${discovery}
