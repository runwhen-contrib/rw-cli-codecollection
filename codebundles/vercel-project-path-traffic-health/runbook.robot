*** Settings ***
Documentation       Analyzes Vercel runtime request logs for popular paths, top 404 routes, and abnormal missing-route spikes for a project.
Metadata            Author    rw-codebundle-agent
Metadata            Display Name    Vercel Project Path Traffic and Missing Routes
Metadata            Supports    Vercel vercel_project traffic observability
Force Tags          Vercel    vercel_project    traffic    observability

Library             String
Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform

Suite Setup         Suite Initialization


*** Tasks ***
Validate Vercel API Access and Resolve Project for `${VERCEL_PROJECT}`
    [Documentation]    Confirms the Vercel token can access the team and that the project id or slug resolves through the REST API.
    [Tags]    Vercel    vercel_project    access:read-only    data:config
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=vercel-validate-project.sh
    ...    env=${env}
    ...    secret__vercel_api_token=${vercel_api_token}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./vercel-validate-project.sh
    ${issues_raw}=    RW.CLI.Run Cli
    ...    cmd=cat vercel_validate_issues.json
    ...    env=${env}
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues_raw.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for validate task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=Vercel API accepts the token and resolves the configured project
            ...    actual=Project validation failed for `${VERCEL_PROJECT}`
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    Vercel project validation:\n${result.stdout}

Resolve Production Deployment for Log Analysis for Project `${VERCEL_PROJECT}`
    [Documentation]    Selects the latest READY production deployment used as the scope for runtime log sampling.
    [Tags]    Vercel    vercel_project    deployment    access:read-only    data:config
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=vercel-resolve-deployment.sh
    ...    env=${env}
    ...    secret__vercel_api_token=${vercel_api_token}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=false
    ...    cmd_override=./vercel-resolve-deployment.sh
    ${issues_raw}=    RW.CLI.Run Cli
    ...    cmd=cat vercel_resolve_issues.json
    ...    env=${env}
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues_raw.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for deployment task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=A production deployment should exist for log analysis
            ...    actual=Deployment resolution reported a problem for `${VERCEL_PROJECT}`
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    Production deployment resolution:\n${result.stdout}

Rank Top Popular Paths by Successful Responses for Project `${VERCEL_PROJECT}`
    [Documentation]    Aggregates runtime logs to list the most visited paths with 2xx responses (and 3xx when enabled) within the lookback window.
    [Tags]    Vercel    vercel_project    traffic    access:read-only    data:metrics
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=vercel-top-paths-popular.sh
    ...    env=${env}
    ...    secret__vercel_api_token=${vercel_api_token}
    ...    timeout_seconds=240
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=false
    ...    cmd_override=LOOKBACK_MINUTES=${LOOKBACK_MINUTES} TOP_N_PATHS=${TOP_N_PATHS} ./vercel-top-paths-popular.sh
    ${issues_raw}=    RW.CLI.Run Cli
    ...    cmd=cat vercel_popular_issues.json
    ...    env=${env}
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues_raw.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for popular paths task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=Popular paths analysis should complete without API errors
            ...    actual=Popular paths task reported an issue for `${VERCEL_PROJECT}`
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    Popular paths:\n${result.stdout}

Rank Top Missing Paths by 404 Count for Project `${VERCEL_PROJECT}`
    [Documentation]    Lists request paths with the highest 404 frequency to surface broken links, stale URLs, or rewrite gaps.
    [Tags]    Vercel    vercel_project    http-404    access:read-only    data:metrics
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=vercel-top-paths-404.sh
    ...    env=${env}
    ...    secret__vercel_api_token=${vercel_api_token}
    ...    timeout_seconds=240
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=false
    ...    cmd_override=LOOKBACK_MINUTES=${LOOKBACK_MINUTES} TOP_N_PATHS=${TOP_N_PATHS} ./vercel-top-paths-404.sh
    ${issues_raw}=    RW.CLI.Run Cli
    ...    cmd=cat vercel_404_rank_issues.json
    ...    env=${env}
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues_raw.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for 404 ranking task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=404 ranking should complete without API errors
            ...    actual=404 ranking reported an issue for `${VERCEL_PROJECT}`
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    Top 404 paths:\n${result.stdout}

Detect Abnormal 404 Spike for Project `${VERCEL_PROJECT}`
    [Documentation]    Compares sampled 404 share to NOT_FOUND_SPIKE_THRESHOLD_PCT when enough requests are present to flag surges in missing-route traffic.
    [Tags]    Vercel    vercel_project    http-404    anomaly    access:read-only    data:metrics
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=vercel-detect-404-spike.sh
    ...    env=${env}
    ...    secret__vercel_api_token=${vercel_api_token}
    ...    timeout_seconds=240
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=false
    ...    cmd_override=NOT_FOUND_SPIKE_THRESHOLD_PCT=${NOT_FOUND_SPIKE_THRESHOLD_PCT} ./vercel-detect-404-spike.sh
    ${issues_raw}=    RW.CLI.Run Cli
    ...    cmd=cat vercel_spike_issues.json
    ...    env=${env}
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues_raw.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for spike task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=404 share should stay below the configured threshold under normal traffic
            ...    actual=404 share exceeded the threshold for `${VERCEL_PROJECT}`
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    404 spike analysis:\n${result.stdout}

Optional Path Prefix Summary for Project `${VERCEL_PROJECT}`
    [Documentation]    Rolls up total requests and 404 counts by first URL segment for coarse-grained trends across large sites.
    [Tags]    Vercel    vercel_project    traffic    access:read-only    data:metrics
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=vercel-summarize-path-prefixes.sh
    ...    env=${env}
    ...    secret__vercel_api_token=${vercel_api_token}
    ...    timeout_seconds=240
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=false
    ...    cmd_override=./vercel-summarize-path-prefixes.sh
    ${issues_raw}=    RW.CLI.Run Cli
    ...    cmd=cat vercel_prefix_issues.json
    ...    env=${env}
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues_raw.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for prefix summary task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=Prefix summary should complete without API errors
            ...    actual=Prefix summary reported an issue for `${VERCEL_PROJECT}`
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    Path prefix summary:\n${result.stdout}


*** Keywords ***
Suite Initialization
    ${vercel_api_token}=    RW.Core.Import Secret    vercel_api_token
    ...    type=string
    ...    description=Vercel bearer token with read access to projects and deployment logs
    ...    pattern=\w*
    ${VERCEL_TEAM_ID}=    RW.Core.Import User Variable    VERCEL_TEAM_ID
    ...    type=string
    ...    description=Vercel team id (teamId) for API scoping
    ...    pattern=\w*
    ${VERCEL_PROJECT}=    RW.Core.Import User Variable    VERCEL_PROJECT
    ...    type=string
    ...    description=Project id or slug to analyze
    ...    pattern=\w*
    ${LOOKBACK_MINUTES}=    RW.Core.Import User Variable    LOOKBACK_MINUTES
    ...    type=string
    ...    description=Log aggregation window in minutes
    ...    pattern=^\d+$
    ...    default=60
    ${TOP_N_PATHS}=    RW.Core.Import User Variable    TOP_N_PATHS
    ...    type=string
    ...    description=How many paths to show in ranked lists
    ...    pattern=^\d+$
    ...    default=25
    ${NOT_FOUND_SPIKE_THRESHOLD_PCT}=    RW.Core.Import User Variable    NOT_FOUND_SPIKE_THRESHOLD_PCT
    ...    type=string
    ...    description=Issue when 404 share of sampled requests exceeds this percent
    ...    pattern=^\d+(\.\d+)?$
    ...    default=15
    ${INCLUDE_3XX}=    RW.Core.Import User Variable    INCLUDE_3XX
    ...    type=string
    ...    description=Include 3xx responses in popular path counts (true/false)
    ...    pattern=\w*
    ...    default=true
    ${SPIKE_MIN_SAMPLE}=    RW.Core.Import User Variable    SPIKE_MIN_SAMPLE
    ...    type=string
    ...    description=Minimum sampled requests before evaluating 404 spike threshold
    ...    pattern=^\d+$
    ...    default=40
    ${LOG_SAMPLE_MAX_LINES}=    RW.Core.Import User Variable    LOG_SAMPLE_MAX_LINES
    ...    type=string
    ...    description=Maximum streamed log lines to process per task
    ...    pattern=^\d+$
    ...    default=50000
    ${LOG_FETCH_MAX_SECONDS}=    RW.Core.Import User Variable    LOG_FETCH_MAX_SECONDS
    ...    type=string
    ...    description=Maximum time to spend reading the runtime log stream
    ...    pattern=^\d+$
    ...    default=90
    Set Suite Variable    ${vercel_api_token}    ${vercel_api_token}
    Set Suite Variable    ${VERCEL_TEAM_ID}    ${VERCEL_TEAM_ID}
    Set Suite Variable    ${VERCEL_PROJECT}    ${VERCEL_PROJECT}
    Set Suite Variable    ${LOOKBACK_MINUTES}    ${LOOKBACK_MINUTES}
    Set Suite Variable    ${TOP_N_PATHS}    ${TOP_N_PATHS}
    Set Suite Variable    ${NOT_FOUND_SPIKE_THRESHOLD_PCT}    ${NOT_FOUND_SPIKE_THRESHOLD_PCT}
    Set Suite Variable    ${INCLUDE_3XX}    ${INCLUDE_3XX}
    Set Suite Variable    ${SPIKE_MIN_SAMPLE}    ${SPIKE_MIN_SAMPLE}
    Set Suite Variable    ${LOG_SAMPLE_MAX_LINES}    ${LOG_SAMPLE_MAX_LINES}
    Set Suite Variable    ${LOG_FETCH_MAX_SECONDS}    ${LOG_FETCH_MAX_SECONDS}
    ${env}=    Create Dictionary
    ...    VERCEL_TEAM_ID=${VERCEL_TEAM_ID}
    ...    VERCEL_PROJECT=${VERCEL_PROJECT}
    ...    LOOKBACK_MINUTES=${LOOKBACK_MINUTES}
    ...    TOP_N_PATHS=${TOP_N_PATHS}
    ...    NOT_FOUND_SPIKE_THRESHOLD_PCT=${NOT_FOUND_SPIKE_THRESHOLD_PCT}
    ...    INCLUDE_3XX=${INCLUDE_3XX}
    ...    SPIKE_MIN_SAMPLE=${SPIKE_MIN_SAMPLE}
    ...    LOG_SAMPLE_MAX_LINES=${LOG_SAMPLE_MAX_LINES}
    ...    LOG_FETCH_MAX_SECONDS=${LOG_FETCH_MAX_SECONDS}
    Set Suite Variable    ${env}    ${env}
