*** Settings ***
Documentation       Monitors the operational health of GCP Cloud Run services in a project, detecting failed revisions, troubled or aborted rollouts, and services that are not Ready or not able to serve traffic.
Metadata            Author    rw-codebundle-agent
Metadata            Display Name    GCP Cloud Run Service Health
Metadata            Supports    GCP,Cloud Run

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             OperatingSystem
Library             Collections

Force Tags          GCP    Cloud Run    cloudrun

Suite Setup         Suite Initialization

*** Tasks ***
List Failed Cloud Run Revisions in GCP Project `${GCP_PROJECT_ID}`
    [Documentation]    Enumerates Cloud Run revisions whose Ready condition is not True (e.g. ContainerStartupFailure, HealthCheckContainerFailed, ResourceExhausted) and raises an issue per failing revision.
    [Tags]    gcloud    cloudrun    gcp    ${GCP_PROJECT_ID}    access:read-only    data:config
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=list_failed_revisions.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./list_failed_revisions.sh
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat failed_revisions_issues.json
    ...    env=${env}
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for failed revisions, defaulting to empty list.    WARN
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
    RW.Core.Add Pre To Report    Failed Cloud Run Revisions Analysis:\n${result.stdout}

Check Cloud Run Services Ready and Serving Traffic in GCP Project `${GCP_PROJECT_ID}`
    [Documentation]    Checks the top-level Ready condition for each Cloud Run service and verifies traffic is routed to a Ready revision that can serve requests, flagging services that are not Ready or serving 0% to the latest ready revision.
    [Tags]    gcloud    cloudrun    gcp    ${GCP_PROJECT_ID}    access:read-only    data:config
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check_services_serving.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./check_services_serving.sh
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat services_serving_issues.json
    ...    env=${env}
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for services serving, defaulting to empty list.    WARN
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
    RW.Core.Add Pre To Report    Cloud Run Services Ready/Serving Analysis:\n${result.stdout}

Detect Troubled or Aborted Cloud Run Rollouts in GCP Project `${GCP_PROJECT_ID}`
    [Documentation]    Identifies rollouts in a non-Serving state during a deploy window -- latest configuration not rolled out, rollback to a prior revision, or a configuration that failed all generation attempts -- and reports the rollout status.
    [Tags]    gcloud    cloudrun    gcp    ${GCP_PROJECT_ID}    access:read-only    data:config
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check_rollouts.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./check_rollouts.sh
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat rollouts_issues.json
    ...    env=${env}
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for rollouts, defaulting to empty list.    WARN
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
    RW.Core.Add Pre To Report    Cloud Run Rollout Analysis:\n${result.stdout}

Get Error Logs for Unhealthy Cloud Run Services in GCP Project `${GCP_PROJECT_ID}`
    [Documentation]    Reads recent ERROR-level log entries (resource.type=cloud_run_revision) for Cloud Run services within a configurable lookback window so the underlying failure cause is available for review.
    [Tags]    gcloud    cloudrun    gcp    ${GCP_PROJECT_ID}    logging    access:read-only    data:logs
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=get_error_logs.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
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
    RW.Core.Add Pre To Report    Cloud Run Error Logs Analysis:\n${result.stdout}

Report Cloud Run Service and Revision Configuration in GCP Project `${GCP_PROJECT_ID}`
    [Documentation]    Dumps service and revision configuration (spec, annotations, concurrency, cpu/memory limits, env, service account, scaling) for all Cloud Run services into the report to enable LLM-based review of service setup.
    [Tags]    gcloud    cloudrun    gcp    ${GCP_PROJECT_ID}    access:read-only    data:config
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=capture_config.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./capture_config.sh
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat config_issues.json
    ...    env=${env}
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for config, defaulting to empty list.    WARN
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
    RW.Core.Add Pre To Report    Cloud Run Service & Revision Configurations:\n${result.stdout}

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
    ...    description=Comma-separated Cloud Run service names to check, or 'All' for auto-discovery.
    ...    pattern=\w*
    ...    default=All
    ${ERROR_LOG_LOOKBACK}=    RW.Core.Import User Variable    ERROR_LOG_LOOKBACK
    ...    type=string
    ...    description=Lookback window for error log queries, e.g. '14d'.
    ...    pattern=\w*
    ...    default=14d
    ${OS_PATH}=    Get Environment Variable    PATH
    Set Suite Variable    ${GCP_PROJECT_ID}    ${GCP_PROJECT_ID}
    Set Suite Variable    ${gcp_credentials}    ${gcp_credentials}
    Set Suite Variable
    ...    ${env}
    ...    {"CLOUDSDK_CORE_PROJECT":"${GCP_PROJECT_ID}","PATH":"$PATH:${OS_PATH}", "GCP_PROJECT_ID":"${GCP_PROJECT_ID}", "RESOURCES":"${RESOURCES}", "ERROR_LOG_LOOKBACK":"${ERROR_LOG_LOOKBACK}"}
    RW.CLI.Run CLI
    ...    cmd=gcloud auth activate-service-account --key-file="./${gcp_credentials.key}" || true
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
