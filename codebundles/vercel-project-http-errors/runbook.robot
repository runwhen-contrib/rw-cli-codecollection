*** Settings ***
Documentation       Surfaces unhealthy HTTP responses from Vercel runtime logs for a project, aggregated by route over a configurable lookback to spot broken links, misconfigured rewrites, and failing handlers.
Metadata            Author    rw-codebundle-agent
Metadata            Display Name    Vercel Project HTTP Error Routes and Logs
Metadata            Supports    Vercel    HTTP    logs    runtime    project

Force Tags          Vercel    HTTP    logs    project    errors

Library             String
Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform

Suite Setup         Suite Initialization

*** Tasks ***
Resolve Vercel Deployments in Time Window for Project `${VERCEL_PROJECT_ID}`
    [Documentation]    Lists deployments whose active interval overlaps the lookback window so log queries use relevant deployment IDs and warns when none cover the window.
    [Tags]    Vercel    deployment    access:read-only    data:logs-config

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=resolve-vercel-deployments-in-window.sh
    ...    env=${env}
    ...    secret__vercel_token=${vercel_token}
    ...    include_in_history=false
    ...    timeout_seconds=240
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./resolve-vercel-deployments-in-window.sh

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat vercel_resolve_issues.json
    ...    timeout_seconds=30
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for resolve task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=At least one READY deployment should overlap the configured lookback window for log attribution
            ...    actual=${issue['details']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    Vercel deployment resolution:\n${result.stdout}

Aggregate 404 Paths from Vercel Runtime Logs for Project `${VERCEL_PROJECT_ID}`
    [Documentation]    Pulls runtime logs for resolved deployments, filters HTTP 404, and aggregates counts and sample timestamps by path and method.
    [Tags]    Vercel    HTTP    404    access:read-only    data:logs

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=aggregate-vercel-404-paths.sh
    ...    env=${env}
    ...    secret__vercel_token=${vercel_token}
    ...    include_in_history=false
    ...    timeout_seconds=300
    ...    show_in_rwl_cheatsheet=false
    ...    cmd_override=./aggregate-vercel-404-paths.sh

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat vercel_aggregate_404_issues.json
    ...    timeout_seconds=30
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for 404 aggregate task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=Aggregation should complete without API errors
            ...    actual=${issue['details']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    Vercel 404 aggregation:\n${result.stdout}

Aggregate 5xx Paths from Vercel Runtime Logs for Project `${VERCEL_PROJECT_ID}`
    [Documentation]    Aggregates server-side HTTP errors (5xx) by path and method from runtime logs for the same deployment scope.
    [Tags]    Vercel    HTTP    5xx    access:read-only    data:logs

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=aggregate-vercel-5xx-paths.sh
    ...    env=${env}
    ...    secret__vercel_token=${vercel_token}
    ...    include_in_history=false
    ...    timeout_seconds=300
    ...    show_in_rwl_cheatsheet=false
    ...    cmd_override=./aggregate-vercel-5xx-paths.sh

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat vercel_aggregate_5xx_issues.json
    ...    timeout_seconds=30
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for 5xx aggregate task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=Aggregation should complete without API errors
            ...    actual=${issue['details']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    Vercel 5xx aggregation:\n${result.stdout}

Aggregate Other Unhealthy HTTP Codes from Vercel Runtime Logs for Project `${VERCEL_PROJECT_ID}`
    [Documentation]    Aggregates additional client error codes configured in UNHEALTHY_HTTP_CODES (for example 408 and 429) by path and method.
    [Tags]    Vercel    HTTP    errors    access:read-only    data:logs

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=aggregate-vercel-other-error-paths.sh
    ...    env=${env}
    ...    secret__vercel_token=${vercel_token}
    ...    include_in_history=false
    ...    timeout_seconds=300
    ...    show_in_rwl_cheatsheet=false
    ...    cmd_override=./aggregate-vercel-other-error-paths.sh

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat vercel_aggregate_other_issues.json
    ...    timeout_seconds=30
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for other-error aggregate task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=Aggregation should complete without API errors
            ...    actual=${issue['details']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    Vercel other-error aggregation:\n${result.stdout}

Build Consolidated Vercel HTTP Error Summary for Project `${VERCEL_PROJECT_ID}`
    [Documentation]    Merges per-code summaries, applies MIN_REQUEST_COUNT_THRESHOLD for noise reduction, and emits consolidated JSON plus a top-routes table for reporting.
    [Tags]    Vercel    HTTP    summary    access:read-only    data:logs

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=report-vercel-http-error-summary.sh
    ...    env=${env}
    ...    include_in_history=false
    ...    timeout_seconds=120
    ...    show_in_rwl_cheatsheet=false
    ...    cmd_override=./report-vercel-http-error-summary.sh

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat vercel_http_error_report_issues.json
    ...    timeout_seconds=30
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for summary task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=No unexpected HTTP error volume above informational thresholds for this window
            ...    actual=${issue['details']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    Vercel HTTP error summary:\n${result.stdout}

*** Keywords ***
Suite Initialization
    TRY
        ${vercel_token}=    RW.Core.Import Secret    vercel_token
        ...    type=string
        ...    description=Vercel API bearer token with read access to project and deployment logs
        ...    pattern=\w*
        Set Suite Variable    ${vercel_token}    ${vercel_token}
    EXCEPT
        Log    vercel_token secret not found; Vercel API tasks will fail until configured.    WARN
        Set Suite Variable    ${vercel_token}    ${EMPTY}
    END

    ${VERCEL_TEAM_ID}=    RW.Core.Import User Variable    VERCEL_TEAM_ID
    ...    type=string
    ...    description=Vercel team slug or ID; leave empty for hobby projects scoped to the token owner
    ...    pattern=^[\w-]*$
    ...    default=${EMPTY}
    ${VERCEL_PROJECT_ID}=    RW.Core.Import User Variable    VERCEL_PROJECT_ID
    ...    type=string
    ...    description=Vercel project ID (prj_...) from the dashboard or API
    ...    pattern=\w+
    ${TIME_WINDOW_HOURS}=    RW.Core.Import User Variable    TIME_WINDOW_HOURS
    ...    type=string
    ...    description=Lookback hours for log aggregation
    ...    pattern=^\d+$
    ...    default=24
    ${DEPLOYMENT_ENVIRONMENT}=    RW.Core.Import User Variable    DEPLOYMENT_ENVIRONMENT
    ...    type=string
    ...    description=production, preview, or all deployments when resolving IDs
    ...    pattern=^(production|preview|all|Production|Preview|All)$
    ...    default=production
    ${UNHEALTHY_HTTP_CODES}=    RW.Core.Import User Variable    UNHEALTHY_HTTP_CODES
    ...    type=string
    ...    description=Comma-separated extra HTTP status codes for the other-errors task
    ...    pattern=^[\d, ]+$
    ...    default=408,429
    ${MIN_REQUEST_COUNT_THRESHOLD}=    RW.Core.Import User Variable    MIN_REQUEST_COUNT_THRESHOLD
    ...    type=string
    ...    description=Minimum requests per path before treating counts as high-severity in the summary
    ...    pattern=^\d+$
    ...    default=5
    ${MAX_DEPLOYMENTS_TO_SCAN}=    RW.Core.Import User Variable    MAX_DEPLOYMENTS_TO_SCAN
    ...    type=string
    ...    description=Maximum deployments to pull runtime logs from per run
    ...    pattern=^\d+$
    ...    default=10
    ${RUNTIME_LOG_MAX_LINES_PER_DEPLOYMENT}=    RW.Core.Import User Variable    RUNTIME_LOG_MAX_LINES_PER_DEPLOYMENT
    ...    type=string
    ...    description=Cap lines read per deployment from the runtime log stream to bound runtime
    ...    pattern=^\d+$
    ...    default=10000

    ${env}=    Create Dictionary
    ...    VERCEL_TEAM_ID=${VERCEL_TEAM_ID}
    ...    VERCEL_PROJECT_ID=${VERCEL_PROJECT_ID}
    ...    TIME_WINDOW_HOURS=${TIME_WINDOW_HOURS}
    ...    DEPLOYMENT_ENVIRONMENT=${DEPLOYMENT_ENVIRONMENT}
    ...    UNHEALTHY_HTTP_CODES=${UNHEALTHY_HTTP_CODES}
    ...    MIN_REQUEST_COUNT_THRESHOLD=${MIN_REQUEST_COUNT_THRESHOLD}
    ...    MAX_DEPLOYMENTS_TO_SCAN=${MAX_DEPLOYMENTS_TO_SCAN}
    ...    RUNTIME_LOG_MAX_LINES_PER_DEPLOYMENT=${RUNTIME_LOG_MAX_LINES_PER_DEPLOYMENT}
    Set Suite Variable    ${VERCEL_TEAM_ID}    ${VERCEL_TEAM_ID}
    Set Suite Variable    ${VERCEL_PROJECT_ID}    ${VERCEL_PROJECT_ID}
    Set Suite Variable    ${TIME_WINDOW_HOURS}    ${TIME_WINDOW_HOURS}
    Set Suite Variable    ${DEPLOYMENT_ENVIRONMENT}    ${DEPLOYMENT_ENVIRONMENT}
    Set Suite Variable    ${UNHEALTHY_HTTP_CODES}    ${UNHEALTHY_HTTP_CODES}
    Set Suite Variable    ${MIN_REQUEST_COUNT_THRESHOLD}    ${MIN_REQUEST_COUNT_THRESHOLD}
    Set Suite Variable    ${MAX_DEPLOYMENTS_TO_SCAN}    ${MAX_DEPLOYMENTS_TO_SCAN}
    Set Suite Variable    ${RUNTIME_LOG_MAX_LINES_PER_DEPLOYMENT}    ${RUNTIME_LOG_MAX_LINES_PER_DEPLOYMENT}
    Set Suite Variable    ${env}    ${env}
