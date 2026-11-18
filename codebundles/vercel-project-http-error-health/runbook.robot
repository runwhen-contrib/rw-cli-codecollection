*** Settings ***
Documentation       Monitors Vercel runtime request logs for a production deployment to surface 4xx/5xx rates, threshold breaches, and top failing paths.
Metadata            Author    rw-codebundle-agent
Metadata            Display Name    Vercel Project HTTP Error Health
Metadata            Supports    Vercel vercel_project HTTP errors runtime logs
Force Tags          Vercel    vercel_project    HTTP    errors    runtime_logs

Library             String
Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform

Suite Setup         Suite Initialization


*** Tasks ***
Validate Vercel API Access and Resolve Project for `${VERCEL_PROJECT}`
    [Documentation]    Confirms the bearer token can read the team scope and resolves the project id or slug, failing fast with a clear issue when credentials or identifiers are wrong.
    [Tags]    Vercel    vercel_project    access:read-only    data:config

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=vercel-validate-project.sh
    ...    env=${env}
    ...    secret__VERCEL_API_TOKEN=${vercel_api_token}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=VERCEL_TEAM_ID="${VERCEL_TEAM_ID}" VERCEL_PROJECT="${VERCEL_PROJECT}" ./vercel-validate-project.sh

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat vercel_validate_issues.json
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=Vercel API should return HTTP 200 and project metadata for `${VERCEL_PROJECT}` under team `${VERCEL_TEAM_ID}`
            ...    actual=Vercel API rejected or could not resolve the project (see details)
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    Validate Vercel project access:\n${result.stdout}

Resolve Production Deployment for Log Analysis for Project `${VERCEL_PROJECT}`
    [Documentation]    Selects the latest READY production deployment used as the log source for the lookback window and documents deployment id and URL in the report.
    [Tags]    Vercel    vercel_project    deployment    access:read-only    data:config

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=vercel-resolve-deployment.sh
    ...    env=${env}
    ...    secret__VERCEL_API_TOKEN=${vercel_api_token}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=VERCEL_TEAM_ID="${VERCEL_TEAM_ID}" VERCEL_PROJECT="${VERCEL_PROJECT}" ./vercel-resolve-deployment.sh

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat vercel_resolve_issues.json
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=A READY production deployment should exist for log analysis
            ...    actual=No suitable production deployment found or deployments API error
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    Resolve production deployment:\n${result.stdout}

Summarize 5xx Server Error Rate for Project `${VERCEL_PROJECT}`
    [Documentation]    Aggregates runtime logs for the deployment, counts HTTP 500-599 responses, compares the error rate to `${ERROR_RATE_THRESHOLD_PCT}` and minimum event count, and raises issues when thresholds are breached.
    [Tags]    Vercel    vercel_project    metrics    5xx    access:read-only    data:metrics

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=vercel-summarize-5xx-rate.sh
    ...    env=${env}
    ...    secret__VERCEL_API_TOKEN=${vercel_api_token}
    ...    timeout_seconds=300
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./vercel-summarize-5xx-rate.sh

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat vercel_5xx_issues.json
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=5xx rate should stay below `${ERROR_RATE_THRESHOLD_PCT}` with sufficient volume to trust the signal
            ...    actual=5xx rate or volume indicates an unhealthy error rate for sampled runtime logs
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    5xx rate summary:\n${result.stdout}

Summarize 4xx Client Error Rate (incl. 400) for Project `${VERCEL_PROJECT}`
    [Documentation]    Aggregates 4xx responses with optional exclusion of 404 when `${EXCLUDE_404_FROM_4XX}` is true, compares rates to thresholds, and highlights application client errors.
    [Tags]    Vercel    vercel_project    metrics    4xx    access:read-only    data:metrics

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=vercel-summarize-4xx-rate.sh
    ...    env=${env}
    ...    secret__VERCEL_API_TOKEN=${vercel_api_token}
    ...    timeout_seconds=300
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./vercel-summarize-4xx-rate.sh

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat vercel_4xx_issues.json
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=Non-404 4xx rate should remain below `${ERROR_RATE_THRESHOLD_PCT}` for sampled traffic
            ...    actual=4xx rate or volume suggests validation, auth, or routing problems in sampled logs
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    4xx rate summary:\n${result.stdout}

List Top Error Paths by 5xx Count for Project `${VERCEL_PROJECT}`
    [Documentation]    Ranks request paths by the volume of 5xx responses in the lookback window to show which routes or assets fail most often.
    [Tags]    Vercel    vercel_project    metrics    paths    access:read-only    data:metrics

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=vercel-top-paths-5xx.sh
    ...    env=${env}
    ...    secret__VERCEL_API_TOKEN=${vercel_api_token}
    ...    timeout_seconds=300
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./vercel-top-paths-5xx.sh

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat vercel_top_5xx_issues.json
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=Top paths table should be available when deployment logs are reachable
            ...    actual=See issue details for path listing failures
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    Top 5xx paths:\n${result.stdout}

List Top Paths by 4xx (non-404) Count for Project `${VERCEL_PROJECT}`
    [Documentation]    Surfaces paths with the highest 4xx counts excluding 404 when configured, highlighting validation and auth issues distinct from missing pages.
    [Tags]    Vercel    vercel_project    metrics    paths    access:read-only    data:metrics

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=vercel-top-paths-4xx.sh
    ...    env=${env}
    ...    secret__VERCEL_API_TOKEN=${vercel_api_token}
    ...    timeout_seconds=300
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./vercel-top-paths-4xx.sh

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat vercel_top_4xx_issues.json
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=Top 4xx paths should be listed when logs are reachable
            ...    actual=See issue details for path listing failures
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    Top 4xx paths:\n${result.stdout}


*** Keywords ***
Suite Initialization
    ${vercel_api_token}=    RW.Core.Import Secret    vercel_api_token
    ...    type=string
    ...    description=Vercel bearer token with read access to projects and deployment runtime logs.
    ...    pattern=\w*

    ${VERCEL_TEAM_ID}=    RW.Core.Import User Variable    VERCEL_TEAM_ID
    ...    type=string
    ...    description=Vercel teamId used to scope REST API calls.
    ...    pattern=\w*

    ${VERCEL_PROJECT}=    RW.Core.Import User Variable    VERCEL_PROJECT
    ...    type=string
    ...    description=Project id or slug to analyze.
    ...    pattern=\w*

    ${LOOKBACK_MINUTES}=    RW.Core.Import User Variable    LOOKBACK_MINUTES
    ...    type=string
    ...    description=Minutes of runtime logs to sample relative to now.
    ...    pattern=^\d+$
    ...    default=60

    ${ERROR_RATE_THRESHOLD_PCT}=    RW.Core.Import User Variable    ERROR_RATE_THRESHOLD_PCT
    ...    type=string
    ...    description=Issue when error rate exceeds this percent of sampled request rows.
    ...    pattern=^\d+(\.\d+)?$
    ...    default=1

    ${MIN_ERROR_EVENTS}=    RW.Core.Import User Variable    MIN_ERROR_EVENTS
    ...    type=string
    ...    description=Minimum error events before raising a high-severity rate issue.
    ...    pattern=^\d+$
    ...    default=5

    ${EXCLUDE_404_FROM_4XX}=    RW.Core.Import User Variable    EXCLUDE_404_FROM_4XX
    ...    type=string
    ...    description=If true, exclude HTTP 404 from 4xx summaries and top-path lists.
    ...    pattern=\w*
    ...    default=true

    Set Suite Variable    ${vercel_api_token}    ${vercel_api_token}
    Set Suite Variable    ${VERCEL_TEAM_ID}    ${VERCEL_TEAM_ID}
    Set Suite Variable    ${VERCEL_PROJECT}    ${VERCEL_PROJECT}
    Set Suite Variable    ${LOOKBACK_MINUTES}    ${LOOKBACK_MINUTES}
    Set Suite Variable    ${ERROR_RATE_THRESHOLD_PCT}    ${ERROR_RATE_THRESHOLD_PCT}
    Set Suite Variable    ${MIN_ERROR_EVENTS}    ${MIN_ERROR_EVENTS}
    Set Suite Variable    ${EXCLUDE_404_FROM_4XX}    ${EXCLUDE_404_FROM_4XX}

    ${env}=    Create Dictionary
    ...    VERCEL_TEAM_ID=${VERCEL_TEAM_ID}
    ...    VERCEL_PROJECT=${VERCEL_PROJECT}
    ...    LOOKBACK_MINUTES=${LOOKBACK_MINUTES}
    ...    ERROR_RATE_THRESHOLD_PCT=${ERROR_RATE_THRESHOLD_PCT}
    ...    MIN_ERROR_EVENTS=${MIN_ERROR_EVENTS}
    ...    EXCLUDE_404_FROM_4XX=${EXCLUDE_404_FROM_4XX}
    Set Suite Variable    ${env}    ${env}
