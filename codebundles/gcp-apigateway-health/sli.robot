*** Settings ***
Documentation       Scores GCP API Gateway health as a 0-1 weighted composite across six dimensions: resource states, config drift, invoker binding, managed service, error rate, and latency. Weights are 0.20/0.20/0.20/0.15/0.15/0.10 per the design spec.
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
Score API Gateway Resource States in `${GCP_PROJECT_ID}`
    [Documentation]    Scores 1.0 if all Api/ApiConfig/Gateway resources are ACTIVE (no state issues), 0.0 otherwise. Weight 0.20.
    [Tags]    gcloud    apigateway    gcp    ${GCP_PROJECT_ID}    data:state    access:read-only
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
    IF    $result.returncode != 0
        Fail    check_states.sh exited ${result.returncode}. The check did not complete, so any output present is stale from an earlier run. Refusing to report a result for a check that failed.
    END
    ${issues_output}=    RW.CLI.Run Cli
    ...    cmd=jq -e 'if type == "array" then length else error("not an array") end' resource_state_issues.json 2>/dev/null || echo INVALID
    ...    env=${env}
    ${issue_count}=    Set Variable    ${issues_output.stdout.strip()}
    IF    not '${issue_count}'.isdigit()
        Fail    The states check did not produce a valid issues file. The check script failed - see the task output above. Refusing to score a check that never ran.
    END
    ${states_score}=    Evaluate    1 if int(${issue_count}) == 0 else 0
    Set Suite Variable    ${states_score}
    RW.Core.Push Metric    ${issue_count}    sub_name=resource_state_issue_count
    RW.Core.Push Metric    ${states_score}    sub_name=resource_states

Score API Gateway Config Drift in `${GCP_PROJECT_ID}`
    [Documentation]    Scores 1.0 if every gateway points at the newest ACTIVE config (no drift), 0.0 otherwise. Weight 0.20.
    [Tags]    gcloud    apigateway    gcp    ${GCP_PROJECT_ID}    data:config    access:read-only
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
    IF    $result.returncode != 0
        Fail    check_config_drift.sh exited ${result.returncode}. The check did not complete, so any output present is stale from an earlier run. Refusing to report a result for a check that failed.
    END
    ${issues_output}=    RW.CLI.Run Cli
    ...    cmd=jq -e 'if type == "array" then length else error("not an array") end' config_drift_issues.json 2>/dev/null || echo INVALID
    ...    env=${env}
    ${issue_count}=    Set Variable    ${issues_output.stdout.strip()}
    IF    not '${issue_count}'.isdigit()
        Fail    The drift check did not produce a valid issues file. The check script failed - see the task output above. Refusing to score a check that never ran.
    END
    ${drift_score}=    Evaluate    1 if int(${issue_count}) == 0 else 0
    Set Suite Variable    ${drift_score}
    RW.Core.Push Metric    ${issue_count}    sub_name=config_drift_count
    RW.Core.Push Metric    ${drift_score}    sub_name=config_drift

Score Gateway Invoker Bindings in `${GCP_PROJECT_ID}`
    [Documentation]    Scores 1.0 if every gateway service account holds roles/run.invoker on its backends, 0.0 otherwise. Weight 0.20.
    [Tags]    gcloud    apigateway    run    gcp    ${GCP_PROJECT_ID}    data:config    access:read-only
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
    IF    $result.returncode != 0
        Fail    check_invoker_binding.sh exited ${result.returncode}. The check did not complete, so any output present is stale from an earlier run. Refusing to report a result for a check that failed.
    END
    ${issues_output}=    RW.CLI.Run Cli
    ...    cmd=jq -e 'if type == "array" then length else error("not an array") end' invoker_binding_issues.json 2>/dev/null || echo INVALID
    ...    env=${env}
    ${issue_count}=    Set Variable    ${issues_output.stdout.strip()}
    IF    not '${issue_count}'.isdigit()
        Fail    The invoker check did not produce a valid issues file. The check script failed - see the task output above. Refusing to score a check that never ran.
    END
    ${invoker_score}=    Evaluate    1 if int(${issue_count}) == 0 else 0
    Set Suite Variable    ${invoker_score}
    RW.Core.Push Metric    ${issue_count}    sub_name=missing_invoker_count
    RW.Core.Push Metric    ${invoker_score}    sub_name=invoker_binding

Score API Gateway Managed Service in `${GCP_PROJECT_ID}`
    [Documentation]    Scores 1.0 if every API's managed service is enabled, 0.0 otherwise. Weight 0.15.
    [Tags]    gcloud    apigateway    gcp    ${GCP_PROJECT_ID}    data:config    access:read-only
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
    IF    $result.returncode != 0
        Fail    check_managed_service.sh exited ${result.returncode}. The check did not complete, so any output present is stale from an earlier run. Refusing to report a result for a check that failed.
    END
    ${issues_output}=    RW.CLI.Run Cli
    ...    cmd=jq -e 'if type == "array" then length else error("not an array") end' managed_service_issues.json 2>/dev/null || echo INVALID
    ...    env=${env}
    ${issue_count}=    Set Variable    ${issues_output.stdout.strip()}
    IF    not '${issue_count}'.isdigit()
        Fail    The managed check did not produce a valid issues file. The check script failed - see the task output above. Refusing to score a check that never ran.
    END
    ${managed_score}=    Evaluate    1 if int(${issue_count}) == 0 else 0
    Set Suite Variable    ${managed_score}
    RW.Core.Push Metric    ${issue_count}    sub_name=managed_service_issue_count
    RW.Core.Push Metric    ${managed_score}    sub_name=managed_service

Score API Gateway Error Rates in `${GCP_PROJECT_ID}`
    [Documentation]    Scores 1.0 if 5xx and 401/403 rates are below thresholds, 0.0 otherwise. Weight 0.15.
    [Tags]    gcloud    apigateway    gcp    ${GCP_PROJECT_ID}    data:metrics    access:read-only
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
    IF    $result.returncode != 0
        Fail    check_error_rates.sh exited ${result.returncode}. The check did not complete, so any output present is stale from an earlier run. Refusing to report a result for a check that failed.
    END
    ${issues_output}=    RW.CLI.Run Cli
    ...    cmd=jq -e 'if type == "array" then length else error("not an array") end' error_rate_issues.json 2>/dev/null || echo INVALID
    ...    env=${env}
    ${issue_count}=    Set Variable    ${issues_output.stdout.strip()}
    IF    not '${issue_count}'.isdigit()
        Fail    The error check did not produce a valid issues file. The check script failed - see the task output above. Refusing to score a check that never ran.
    END
    ${error_score}=    Evaluate    1 if int(${issue_count}) == 0 else 0
    Set Suite Variable    ${error_score}
    RW.Core.Push Metric    ${issue_count}    sub_name=high_error_rate_count
    RW.Core.Push Metric    ${error_score}    sub_name=error_rate

Score API Gateway Latency in `${GCP_PROJECT_ID}`
    [Documentation]    Scores 1.0 if p95 latency and the gateway-vs-backend gap are below thresholds, 0.0 otherwise. Weight 0.10.
    [Tags]    gcloud    apigateway    gcp    ${GCP_PROJECT_ID}    data:metrics    access:read-only
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
    IF    $result.returncode != 0
        Fail    check_latency.sh exited ${result.returncode}. The check did not complete, so any output present is stale from an earlier run. Refusing to report a result for a check that failed.
    END
    ${issues_output}=    RW.CLI.Run Cli
    ...    cmd=jq -e 'if type == "array" then length else error("not an array") end' latency_issues.json 2>/dev/null || echo INVALID
    ...    env=${env}
    ${issue_count}=    Set Variable    ${issues_output.stdout.strip()}
    IF    not '${issue_count}'.isdigit()
        Fail    The latency check did not produce a valid issues file. The check script failed - see the task output above. Refusing to score a check that never ran.
    END
    ${latency_score}=    Evaluate    1 if int(${issue_count}) == 0 else 0
    Set Suite Variable    ${latency_score}
    RW.Core.Push Metric    ${issue_count}    sub_name=high_latency_count
    RW.Core.Push Metric    ${latency_score}    sub_name=latency

Generate Aggregate API Gateway Health Score in `${GCP_PROJECT_ID}`
    [Documentation]    Combines the six weighted dimension sub-scores into the final 0-1 health score. Fails with the list of dimensions that did not produce a score, rather than scoring from a partial set.
    [Tags]    gcloud    apigateway    gcp    ${GCP_PROJECT_ID}    data:metrics    access:read-only
    # A failed check never reaches its `Set Suite Variable`, so its score is
    # simply undefined here. Reading it directly raises "Variable '${x}' not
    # found", which buries the real failure under a confusing secondary error.
    # Collect what is missing and say so plainly instead.
    ${missing}=    Create List
    ${states_score}=      Get Variable Value    ${states_score}      ${None}
    ${drift_score}=       Get Variable Value    ${drift_score}       ${None}
    ${invoker_score}=     Get Variable Value    ${invoker_score}     ${None}
    ${managed_score}=     Get Variable Value    ${managed_score}     ${None}
    ${error_score}=       Get Variable Value    ${error_score}       ${None}
    ${latency_score}=     Get Variable Value    ${latency_score}     ${None}
    IF    $states_score is None      Append To List    ${missing}    resource states
    IF    $drift_score is None       Append To List    ${missing}    config drift
    IF    $invoker_score is None     Append To List    ${missing}    invoker bindings
    IF    $managed_score is None     Append To List    ${missing}    managed service
    IF    $error_score is None       Append To List    ${missing}    error rate
    IF    $latency_score is None     Append To List    ${missing}    latency
    IF    len(${missing}) > 0
        ${missing_csv}=    Evaluate    ", ".join($missing)
        Fail    Cannot compute an aggregate health score: ${missing_csv} did not produce a sub-score because the underlying check failed. Scoring from the remaining dimensions would understate the failure. Fix the failing check(s) above.
    END
    ${health_score}=    Evaluate    (${states_score} * 0.20) + (${drift_score} * 0.20) + (${invoker_score} * 0.20) + (${managed_score} * 0.15) + (${error_score} * 0.15) + (${latency_score} * 0.10)
    ${health_score}=    Convert to Number    ${health_score}    2
    RW.Core.Add to Report    API Gateway Health Score: ${health_score} -- states: ${states_score}, drift: ${drift_score}, invoker: ${invoker_score}, managed: ${managed_score}, error_rate: ${error_score}, latency: ${latency_score}
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
    ...    description=The GCP Project ID that hosts the API Gateways to check.
    ...    pattern=\w*
    ...    example=myproject-ID
    ${GCP_REGIONS}=    RW.Core.Import User Variable    GCP_REGIONS
    ...    type=string
    ...    description=Comma-separated list of regions to search for regional Gateways. Empty means discover dynamically.
    ...    pattern=\w*
    ...    default=
    ${METRIC_LOOKBACK_PERIOD}=    RW.Core.Import User Variable    METRIC_LOOKBACK_PERIOD
    ...    type=string
    ...    description=Cloud Monitoring lookback period for metric queries (seconds).
    ...    pattern=^\d+s$
    ...    default=3600s
    ${ERROR_RATE_THRESHOLD}=    RW.Core.Import User Variable    ERROR_RATE_THRESHOLD
    ...    type=string
    ...    description=Maximum acceptable 5xx error ratio (0.01 = 1%).
    ...    pattern=^\d*\.?\d+$
    ...    default=0.01
    ${AUTH_ERROR_RATE_THRESHOLD}=    RW.Core.Import User Variable    AUTH_ERROR_RATE_THRESHOLD
    ...    type=string
    ...    description=Tighter maximum acceptable 401/403 ratio.
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
    Set Suite Variable    ${GCP_PROJECT_ID}    ${GCP_PROJECT_ID}
    Set Suite Variable    ${gcp_credentials}    ${gcp_credentials}
    Set Suite Variable    ${GCP_REGIONS}    ${GCP_REGIONS}
    Set Suite Variable    ${METRIC_LOOKBACK_PERIOD}    ${METRIC_LOOKBACK_PERIOD}
    Set Suite Variable    ${ERROR_RATE_THRESHOLD}    ${ERROR_RATE_THRESHOLD}
    Set Suite Variable    ${AUTH_ERROR_RATE_THRESHOLD}    ${AUTH_ERROR_RATE_THRESHOLD}
    Set Suite Variable    ${LATENCY_THRESHOLD_MS}    ${LATENCY_THRESHOLD_MS}
    Set Suite Variable    ${LATENCY_GAP_THRESHOLD_MS}    ${LATENCY_GAP_THRESHOLD_MS}
    ${OS_PATH}=    Get Environment Variable    PATH
    Set Suite Variable
    ...    ${env}
    ...    {"CLOUDSDK_CORE_PROJECT":"${GCP_PROJECT_ID}","PATH":"$PATH:${OS_PATH}","GCP_PROJECT_ID":"${GCP_PROJECT_ID}","GCP_REGIONS":"${GCP_REGIONS}","METRIC_LOOKBACK_PERIOD":"${METRIC_LOOKBACK_PERIOD}","ERROR_RATE_THRESHOLD":"${ERROR_RATE_THRESHOLD}","AUTH_ERROR_RATE_THRESHOLD":"${AUTH_ERROR_RATE_THRESHOLD}","LATENCY_THRESHOLD_MS":"${LATENCY_THRESHOLD_MS}","LATENCY_GAP_THRESHOLD_MS":"${LATENCY_GAP_THRESHOLD_MS}"}
    RW.CLI.Run CLI
    ...    cmd=gcloud auth activate-service-account --key-file="./${gcp_credentials.key}" || true
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    # Every check below reads apigateway_inventory.json. Without this, the file
    # never exists in the SLI flow and each check iterates an empty inventory,
    # reports zero issues and scores 1.0 -- a broken project would read as
    # perfectly healthy. The runbook runs discovery as its first task; the SLI
    # has no equivalent task, so it runs here.
    # Remove any output from a previous run first. The working directory is
    # reused between runs, so a stale file would otherwise be read as this
    # run's result even when the check below never writes one.
    RW.CLI.Run Cli
    ...    cmd=rm -f apigateway_inventory.json apigateway_discovery_issues.json
    ...    env=${env}
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=discover_apigateway.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    IF    $result.returncode != 0
        Fail    discover_apigateway.sh exited ${result.returncode}. The check did not complete, so any output present is stale from an earlier run. Refusing to report a result for a check that failed.
    END
