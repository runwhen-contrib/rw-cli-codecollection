*** Settings ***
Documentation       Vercel project health — project configuration snapshot, recent deployments with git branches, and unhealthy HTTP responses from runtime logs aggregated by route over a configurable lookback. Optionally iterate multiple projects via VERCEL_PROJECT_IDS (comma-separated); artifacts land under VERCEL_ARTIFACT_ROOT/<project_id>/ when more than one project is configured.
Metadata            Author    rw-codebundle-agent
Metadata            Display Name    Vercel Project Health
Metadata            Supports    Vercel    HTTP    logs    runtime    project    deployments

Force Tags          Vercel    HTTP    logs    project    errors    health

Library             String
Library             Collections
Library             RW.Core
Library             RW.CLI
Library             RW.platform

Suite Setup         Suite Initialization

*** Tasks ***
Fetch Vercel Project Configuration for Configured Project(s)
    [Documentation]    GET /v9/projects — writes sanitized project metadata per project under VERCEL_ARTIFACT_DIR (see suite vars).
    [Tags]    Vercel    config    access:read-only    data:logs-config

    FOR    ${pid}    IN    @{PROJECT_IDS}
        Fetch Vercel Project Configuration Worker    ${pid}
    END

Report Vercel Deployment Branches and Status for Configured Project(s)
    [Documentation]    Lists recent production and preview deployments (all targets), git branch and commit metadata, and summary hints such as latest production READY state.
    [Tags]    Vercel    deployments    git    access:read-only    data:logs-config

    FOR    ${pid}    IN    @{PROJECT_IDS}
        Report Vercel Deployment Branches Worker    ${pid}
    END

Diagnose Recent Failed Vercel Deployments for Configured Project(s)
    [Documentation]    For each ERROR/CANCELED entry in the deployment-branches snapshot (capped by MAX_FAILED_DEPLOYMENTS_TO_DIAGNOSE), pulls GET /v13/deployments/{id} and surfaces the actual errorCode + errorMessage + branch + commit so on-call sees the real failure reason instead of just a count.
    [Tags]    Vercel    deployments    diagnose    access:read-only    data:logs-config

    FOR    ${pid}    IN    @{PROJECT_IDS}
        Diagnose Recent Failed Vercel Deployments Worker    ${pid}
    END

Verify Vercel Project Production Domains for Configured Project(s)
    [Documentation]    Calls GET /v9/projects/{id}/domains, separates production-bound hostnames from preview/custom-environment aliases, reports verification + redirect state, and raises one issue per unverified production domain (with the TXT/CNAME records the user needs to add).
    [Tags]    Vercel    domains    access:read-only    data:logs-config

    FOR    ${pid}    IN    @{PROJECT_IDS}
        Verify Vercel Project Domains Worker    ${pid}
    END

Resolve Vercel Deployments in Time Window for Configured Project(s)
    [Documentation]    Lists deployments whose active interval overlaps the lookback window so log queries use relevant deployment IDs and warns when none cover the window.
    [Tags]    Vercel    deployment    access:read-only    data:logs-config

    FOR    ${pid}    IN    @{PROJECT_IDS}
        Resolve Vercel Deployments In Window Worker    ${pid}
    END

Collect Vercel Request Logs for Configured Project(s)
    [Documentation]    Hits Vercel's historical request-logs endpoint (the same one the dashboard's "Logs" page uses) for the lookback window, paginates rows, and writes vercel_request_log_rows.json. The 4xx / 5xx / other aggregate tasks read this file directly instead of issuing more API calls. Filtered to VERCEL_REQUEST_LOGS_ENV (default: production) so we only score what real users hit.
    [Tags]    Vercel    HTTP    logs    access:read-only    data:logs

    FOR    ${pid}    IN    @{PROJECT_IDS}
        Collect Vercel Request Logs Worker    ${pid}
    END

Aggregate 4xx Paths from Vercel Request Logs for Configured Project(s)
    [Documentation]    Reads the shared request-log rows and aggregates ALL 4xx responses (400-499) by code, path, and method. Surfaces 401/403/422/etc. that a 404-only filter would drop.
    [Tags]    Vercel    HTTP    4xx    access:read-only    data:logs

    FOR    ${pid}    IN    @{PROJECT_IDS}
        Aggregate Vercel 4xx Paths Worker    ${pid}
    END

Aggregate 5xx Paths from Vercel Request Logs for Configured Project(s)
    [Documentation]    Aggregates server-side HTTP errors (5xx) by code, path, and method from the shared request-log rows.
    [Tags]    Vercel    HTTP    5xx    access:read-only    data:logs

    FOR    ${pid}    IN    @{PROJECT_IDS}
        Aggregate Vercel 5xx Paths Worker    ${pid}
    END

Aggregate Other Unhealthy HTTP Codes from Vercel Request Logs for Configured Project(s)
    [Documentation]    Aggregates additional client error codes configured in UNHEALTHY_HTTP_CODES (for example 408 and 429) by code, path, and method from the shared request-log rows.
    [Tags]    Vercel    HTTP    errors    access:read-only    data:logs

    FOR    ${pid}    IN    @{PROJECT_IDS}
        Aggregate Vercel Other Error Paths Worker    ${pid}
    END

Build Consolidated Vercel HTTP Error Summary for Configured Project(s)
    [Documentation]    Merges per-code summaries, applies MIN_REQUEST_COUNT_THRESHOLD for noise reduction, and emits consolidated JSON plus a top-routes table for reporting.
    [Tags]    Vercel    HTTP    summary    access:read-only    data:logs

    FOR    ${pid}    IN    @{PROJECT_IDS}
        Build Vercel Http Error Summary Worker    ${pid}
    END

Probe Production URL Paths for Configured Project(s)
    [Documentation]    Synthetic HTTP GET probe against configurable paths on the latest production URL. Catches what historical logs miss (DNS / cert / cold-start timeouts, regional CDN issues, no-traffic blind spots) and complements the request-logs aggregations. Configure VERCEL_PROBE_PATHS, VERCEL_PROBE_BASE_URL (optional override), VERCEL_PROBE_TIMEOUT_SECONDS, VERCEL_PROBE_SLOW_MS.
    [Tags]    Vercel    HTTP    probe    access:read-only    data:probe

    FOR    ${pid}    IN    @{PROJECT_IDS}
        Probe Vercel Production URLs Worker    ${pid}
    END

*** Keywords ***
Add Vercel Rest Api Context To Report
    [Documentation]    Pinned links to the Vercel REST endpoints this bundle exercises and a note on which endpoint backs each task.
    RW.Core.Add Pre To Report    Vercel REST API reference:\n- List deployments (GET /v6/deployments): https://vercel.com/docs/rest-api/reference/endpoints/deployments/list-deployments\n- Find project by id or name (GET /v9/projects/{idOrName}): https://vercel.com/docs/rest-api/reference/endpoints/projects/find-a-project-by-id-or-name\n- OpenAPI (all endpoints): https://openapi.vercel.sh/\n\nHistorical request logs are fetched via the dashboard-backing endpoint:\n- GET https://vercel.com/api/logs/request-logs?projectId=...&ownerId=...&startDate=<ms>&endDate=<ms>&page=N\nThis is the same endpoint Vercel's "Logs" page and `vercel logs` v2 use. It supports time-range queries and server-side filtering by environment / statusCode / source / deploymentId / branch. It is undocumented in the public REST reference but stable enough that the official CLI ships with it on `main`. Retention is roughly the last ~3 days; pipe to a Log Drain (https://vercel.com/docs/log-drains) for longer-term analysis.\n\nThe published /v1/projects/{pid}/deployments/{depid}/runtime-logs endpoint is live-tail only and cannot be used for historical aggregation, so the bundle no longer streams it.\n\nThe Probe Production URL Paths task complements the log scan with a synthetic HTTP GET against configurable paths on the latest production URL — useful for catching DNS / cert / cold-start failures the logs cannot show on idle projects.

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
    ...    description=Single Vercel project ID (prj_...); ignored when VERCEL_PROJECT_IDS is non-empty
    ...    pattern=^[\w-]*$
    ...    default=${EMPTY}
    ${VERCEL_PROJECT_IDS}=    RW.Core.Import User Variable    VERCEL_PROJECT_IDS
    ...    type=string
    ...    description=Optional comma-separated project IDs for multi-project runs (overrides single ID when set)
    ...    pattern=^[\w,\s-]*$
    ...    default=${EMPTY}
    ${VERCEL_ARTIFACT_ROOT}=    RW.Core.Import User Variable    VERCEL_ARTIFACT_ROOT
    ...    type=string
    ...    description=Parent directory for per-project JSON outputs when multiple projects are configured
    ...    pattern=^[\w./~-]*$
    ...    default=.vercel-health-projects
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
    ${VERCEL_REQUEST_LOGS_ENV}=    RW.Core.Import User Variable    VERCEL_REQUEST_LOGS_ENV
    ...    type=string
    ...    description=Filter passed to the historical request-logs endpoint. Use 'production' (default) to score only what real users hit, 'preview' for branch deployments, or 'all' to combine.
    ...    pattern=^(production|preview|all)$
    ...    default=production
    ${VERCEL_REQUEST_LOGS_MAX_ROWS}=    RW.Core.Import User Variable    VERCEL_REQUEST_LOGS_MAX_ROWS
    ...    type=string
    ...    description=Cap on rows fetched from the historical request-logs endpoint per project per run. Stops paginating once reached.
    ...    pattern=^\d+$
    ...    default=5000
    ${VERCEL_REQUEST_LOGS_MAX_PAGES}=    RW.Core.Import User Variable    VERCEL_REQUEST_LOGS_MAX_PAGES
    ...    type=string
    ...    description=Hard cap on pages walked even when hasMoreRows=true; bounds wall-clock for very busy projects.
    ...    pattern=^\d+$
    ...    default=20
    ${VERCEL_PROBE_PATHS}=    RW.Core.Import User Variable    VERCEL_PROBE_PATHS
    ...    type=string
    ...    description=Comma-separated paths to synthetic-probe against the production URL. Empty disables the probe task.
    ...    pattern=^.*$
    ...    default=/
    ${VERCEL_PROBE_BASE_URL}=    RW.Core.Import User Variable    VERCEL_PROBE_BASE_URL
    ...    type=string
    ...    description=Optional explicit base URL for the synthetic probe; auto-resolved from the latest READY production deployment when empty.
    ...    pattern=^.*$
    ...    default=${EMPTY}
    ${VERCEL_PROBE_TIMEOUT_SECONDS}=    RW.Core.Import User Variable    VERCEL_PROBE_TIMEOUT_SECONDS
    ...    type=string
    ...    description=Per-request timeout for the synthetic probe (seconds).
    ...    pattern=^\d+$
    ...    default=10
    ${VERCEL_PROBE_SLOW_MS}=    RW.Core.Import User Variable    VERCEL_PROBE_SLOW_MS
    ...    type=string
    ...    description=Probe latency threshold in ms; requests slower than this raise an informational issue.
    ...    pattern=^\d+$
    ...    default=2000
    ${DEPLOYMENT_SNAPSHOT_LIMIT}=    RW.Core.Import User Variable    DEPLOYMENT_SNAPSHOT_LIMIT
    ...    type=string
    ...    description=Maximum deployments to include in the branch/status snapshot (most recent first)
    ...    pattern=^\d+$
    ...    default=25
    ${MAX_FAILED_DEPLOYMENTS_TO_DIAGNOSE}=    RW.Core.Import User Variable    MAX_FAILED_DEPLOYMENTS_TO_DIAGNOSE
    ...    type=string
    ...    description=Maximum recent ERROR/CANCELED deployments to enrich with build-error reason via GET /v13/deployments/{id}. Each adds one API call, so keep this small.
    ...    pattern=^\d+$
    ...    default=2

    Build Project Id List
    ${env_base}=    Create Dictionary
    ...    VERCEL_TEAM_ID=${VERCEL_TEAM_ID}
    ...    TIME_WINDOW_HOURS=${TIME_WINDOW_HOURS}
    ...    DEPLOYMENT_ENVIRONMENT=${DEPLOYMENT_ENVIRONMENT}
    ...    UNHEALTHY_HTTP_CODES=${UNHEALTHY_HTTP_CODES}
    ...    MIN_REQUEST_COUNT_THRESHOLD=${MIN_REQUEST_COUNT_THRESHOLD}
    ...    VERCEL_REQUEST_LOGS_ENV=${VERCEL_REQUEST_LOGS_ENV}
    ...    VERCEL_REQUEST_LOGS_MAX_ROWS=${VERCEL_REQUEST_LOGS_MAX_ROWS}
    ...    VERCEL_REQUEST_LOGS_MAX_PAGES=${VERCEL_REQUEST_LOGS_MAX_PAGES}
    ...    VERCEL_PROBE_PATHS=${VERCEL_PROBE_PATHS}
    ...    VERCEL_PROBE_BASE_URL=${VERCEL_PROBE_BASE_URL}
    ...    VERCEL_PROBE_TIMEOUT_SECONDS=${VERCEL_PROBE_TIMEOUT_SECONDS}
    ...    VERCEL_PROBE_SLOW_MS=${VERCEL_PROBE_SLOW_MS}
    ...    DEPLOYMENT_SNAPSHOT_LIMIT=${DEPLOYMENT_SNAPSHOT_LIMIT}
    ...    MAX_FAILED_DEPLOYMENTS_TO_DIAGNOSE=${MAX_FAILED_DEPLOYMENTS_TO_DIAGNOSE}
    Set Suite Variable    ${env_base}    ${env_base}
    Set Suite Variable    ${VERCEL_TEAM_ID}    ${VERCEL_TEAM_ID}
    Set Suite Variable    ${VERCEL_PROJECT_ID}    ${VERCEL_PROJECT_ID}
    Set Suite Variable    ${VERCEL_PROJECT_IDS}    ${VERCEL_PROJECT_IDS}
    Set Suite Variable    ${VERCEL_ARTIFACT_ROOT}    ${VERCEL_ARTIFACT_ROOT}
    Set Suite Variable    ${TIME_WINDOW_HOURS}    ${TIME_WINDOW_HOURS}
    Set Suite Variable    ${DEPLOYMENT_ENVIRONMENT}    ${DEPLOYMENT_ENVIRONMENT}
    Set Suite Variable    ${UNHEALTHY_HTTP_CODES}    ${UNHEALTHY_HTTP_CODES}
    Set Suite Variable    ${MIN_REQUEST_COUNT_THRESHOLD}    ${MIN_REQUEST_COUNT_THRESHOLD}
    Set Suite Variable    ${VERCEL_REQUEST_LOGS_ENV}    ${VERCEL_REQUEST_LOGS_ENV}
    Set Suite Variable    ${VERCEL_REQUEST_LOGS_MAX_ROWS}    ${VERCEL_REQUEST_LOGS_MAX_ROWS}
    Set Suite Variable    ${VERCEL_REQUEST_LOGS_MAX_PAGES}    ${VERCEL_REQUEST_LOGS_MAX_PAGES}
    Set Suite Variable    ${VERCEL_PROBE_PATHS}    ${VERCEL_PROBE_PATHS}
    Set Suite Variable    ${VERCEL_PROBE_BASE_URL}    ${VERCEL_PROBE_BASE_URL}
    Set Suite Variable    ${VERCEL_PROBE_TIMEOUT_SECONDS}    ${VERCEL_PROBE_TIMEOUT_SECONDS}
    Set Suite Variable    ${VERCEL_PROBE_SLOW_MS}    ${VERCEL_PROBE_SLOW_MS}
    Set Suite Variable    ${DEPLOYMENT_SNAPSHOT_LIMIT}    ${DEPLOYMENT_SNAPSHOT_LIMIT}
    Set Suite Variable    ${MAX_FAILED_DEPLOYMENTS_TO_DIAGNOSE}    ${MAX_FAILED_DEPLOYMENTS_TO_DIAGNOSE}
    Add Vercel Rest Api Context To Report

Artifact Dir For Project
    [Arguments]    ${pid}
    ${n}=    Get Length    ${PROJECT_IDS}
    IF    ${n} > 1
        ${d}=    Catenate    SEPARATOR=/    ${VERCEL_ARTIFACT_ROOT}    ${pid}
    ELSE
        ${d}=    Set Variable    .
    END
    RETURN    ${d}

Env For Project With Artifact
    [Arguments]    ${pid}
    ${dir}=    Artifact Dir For Project    ${pid}
    ${e}=    Copy Dictionary    ${env_base}
    Set To Dictionary    ${e}    VERCEL_PROJECT_ID=${pid}    VERCEL_ARTIFACT_DIR=${dir}
    RETURN    ${e}

Build Project Id List
    ${list_raw}=    Strip String    ${VERCEL_PROJECT_IDS}
    IF    '${list_raw}' != '${EMPTY}'
        @{parts}=    Split String    ${list_raw}    ,
        @{ids}=    Create List
        FOR    ${p}    IN    @{parts}
            ${q}=    Strip String    ${p}
            IF    '${q}' != '${EMPTY}'
                Append To List    ${ids}    ${q}
            END
        END
        ${cnt}=    Get Length    ${ids}
        Should Be True    ${cnt} > 0    VERCEL_PROJECT_IDS was empty after parsing
        Set Suite Variable    @{PROJECT_IDS}    @{ids}
    ELSE IF    '${VERCEL_PROJECT_ID}' != '${EMPTY}'
        @{ids}=    Create List    ${VERCEL_PROJECT_ID}
        Set Suite Variable    @{PROJECT_IDS}    @{ids}
    ELSE
        Fail    Configure VERCEL_PROJECT_ID or VERCEL_PROJECT_IDS (comma-separated project IDs).
    END

Fetch Vercel Project Configuration Worker
    [Arguments]    ${pid}
    ${env}=    Env For Project With Artifact    ${pid}
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=report-vercel-project-config.sh
    ...    env=${env}
    ...    secret__vercel_token=${vercel_token}
    ...    include_in_history=false
    ...    timeout_seconds=90
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./report-vercel-project-config.sh
    ${dir}=    Artifact Dir For Project    ${pid}
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat ${dir}/vercel_project_config_issues.json
    ...    timeout_seconds=30
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for project config task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=Vercel project metadata should load successfully with read token
            ...    actual=${issue['details']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    Vercel project configuration (${pid}):\n${result.stdout}

Report Vercel Deployment Branches Worker
    [Arguments]    ${pid}
    ${env}=    Env For Project With Artifact    ${pid}
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=report-vercel-deployment-branches.sh
    ...    env=${env}
    ...    secret__vercel_token=${vercel_token}
    ...    include_in_history=false
    ...    timeout_seconds=180
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./report-vercel-deployment-branches.sh
    ${dir}=    Artifact Dir For Project    ${pid}
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat ${dir}/vercel_deployments_snapshot_issues.json
    ...    timeout_seconds=30
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for deployment snapshot task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=Deployments should list successfully and production should be READY when serving traffic
            ...    actual=${issue['details']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    Vercel deployment branch snapshot (${pid}):\n${result.stdout}

Diagnose Recent Failed Vercel Deployments Worker
    [Arguments]    ${pid}
    ${env}=    Env For Project With Artifact    ${pid}
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=diagnose-recent-failed-deployments.sh
    ...    env=${env}
    ...    secret__vercel_token=${vercel_token}
    ...    include_in_history=false
    ...    timeout_seconds=120
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./diagnose-recent-failed-deployments.sh
    ${dir}=    Artifact Dir For Project    ${pid}
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat ${dir}/vercel_failed_deployment_diagnoses_issues.json
    ...    timeout_seconds=30
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for failed-deploy diagnostic task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=Recent deployments should complete with state READY; failures should carry a clear errorCode + errorMessage
            ...    actual=${issue['details']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    Vercel failed deployment diagnostics (${pid}):\n${result.stdout}

Verify Vercel Project Domains Worker
    [Arguments]    ${pid}
    ${env}=    Env For Project With Artifact    ${pid}
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=report-vercel-project-domains.sh
    ...    env=${env}
    ...    secret__vercel_token=${vercel_token}
    ...    include_in_history=false
    ...    timeout_seconds=60
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./report-vercel-project-domains.sh
    ${dir}=    Artifact Dir For Project    ${pid}
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat ${dir}/vercel_project_domains_issues.json
    ...    timeout_seconds=30
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for project-domains task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=Every production domain attached to the project should be verified
            ...    actual=${issue['details']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    Vercel project domains (${pid}):\n${result.stdout}

Resolve Vercel Deployments In Window Worker
    [Arguments]    ${pid}
    ${env}=    Env For Project With Artifact    ${pid}
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=resolve-vercel-deployments-in-window.sh
    ...    env=${env}
    ...    secret__vercel_token=${vercel_token}
    ...    include_in_history=false
    ...    timeout_seconds=240
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./resolve-vercel-deployments-in-window.sh
    ${dir}=    Artifact Dir For Project    ${pid}
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat ${dir}/vercel_resolve_issues.json
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
    RW.Core.Add Pre To Report    Vercel deployment resolution (${pid}):\n${result.stdout}

Collect Vercel Request Logs Worker
    [Arguments]    ${pid}
    ${env}=    Env For Project With Artifact    ${pid}
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=collect-vercel-request-logs.sh
    ...    env=${env}
    ...    secret__vercel_token=${vercel_token}
    ...    include_in_history=false
    ...    timeout_seconds=180
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./collect-vercel-request-logs.sh
    ${dir}=    Artifact Dir For Project    ${pid}
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat ${dir}/vercel_request_log_rows_issues.json
    ...    timeout_seconds=30
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for request-log collector task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=Vercel historical request-logs endpoint should respond and return rows when traffic exists in the window
            ...    actual=${issue['details']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    Vercel request log collection (${pid}):\n${result.stdout}

Probe Vercel Production URLs Worker
    [Arguments]    ${pid}
    ${env}=    Env For Project With Artifact    ${pid}
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=probe-vercel-production-urls.sh
    ...    env=${env}
    ...    secret__vercel_token=${vercel_token}
    ...    include_in_history=false
    ...    timeout_seconds=180
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./probe-vercel-production-urls.sh
    ${dir}=    Artifact Dir For Project    ${pid}
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat ${dir}/vercel_synthetic_probe_issues.json
    ...    timeout_seconds=30
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for probe task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=Production URL paths should respond with 2xx and within VERCEL_PROBE_SLOW_MS
            ...    actual=${issue['details']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    Vercel synthetic probe (${pid}):\n${result.stdout}

Aggregate Vercel 4xx Paths Worker
    [Arguments]    ${pid}
    ${env}=    Env For Project With Artifact    ${pid}
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=aggregate-vercel-4xx-paths.sh
    ...    env=${env}
    ...    secret__vercel_token=${vercel_token}
    ...    include_in_history=false
    ...    timeout_seconds=60
    ...    show_in_rwl_cheatsheet=false
    ...    cmd_override=./aggregate-vercel-4xx-paths.sh
    ${dir}=    Artifact Dir For Project    ${pid}
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat ${dir}/vercel_aggregate_4xx_issues.json
    ...    timeout_seconds=30
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for 4xx aggregate task, defaulting to empty list.    WARN
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
    RW.Core.Add Pre To Report    Vercel 4xx aggregation (${pid}):\n${result.stdout}

Aggregate Vercel 5xx Paths Worker
    [Arguments]    ${pid}
    ${env}=    Env For Project With Artifact    ${pid}
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=aggregate-vercel-5xx-paths.sh
    ...    env=${env}
    ...    secret__vercel_token=${vercel_token}
    ...    include_in_history=false
    ...    timeout_seconds=60
    ...    show_in_rwl_cheatsheet=false
    ...    cmd_override=./aggregate-vercel-5xx-paths.sh
    ${dir}=    Artifact Dir For Project    ${pid}
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat ${dir}/vercel_aggregate_5xx_issues.json
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
    RW.Core.Add Pre To Report    Vercel 5xx aggregation (${pid}):\n${result.stdout}

Aggregate Vercel Other Error Paths Worker
    [Arguments]    ${pid}
    ${env}=    Env For Project With Artifact    ${pid}
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=aggregate-vercel-other-error-paths.sh
    ...    env=${env}
    ...    secret__vercel_token=${vercel_token}
    ...    include_in_history=false
    ...    timeout_seconds=60
    ...    show_in_rwl_cheatsheet=false
    ...    cmd_override=./aggregate-vercel-other-error-paths.sh
    ${dir}=    Artifact Dir For Project    ${pid}
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat ${dir}/vercel_aggregate_other_issues.json
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
    RW.Core.Add Pre To Report    Vercel other-error aggregation (${pid}):\n${result.stdout}

Build Vercel Http Error Summary Worker
    [Arguments]    ${pid}
    ${env}=    Env For Project With Artifact    ${pid}
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=report-vercel-http-error-summary.sh
    ...    env=${env}
    ...    include_in_history=false
    ...    timeout_seconds=120
    ...    show_in_rwl_cheatsheet=false
    ...    cmd_override=./report-vercel-http-error-summary.sh
    ${dir}=    Artifact Dir For Project    ${pid}
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat ${dir}/vercel_http_error_report_issues.json
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
    RW.Core.Add Pre To Report    Vercel HTTP error summary (${pid}):\n${result.stdout}
