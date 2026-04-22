*** Settings ***
Documentation       Measures Vercel project reachability and a lightweight runtime HTTP error sample. Produces a score between 0 (failing) and 1 (healthy).
Metadata            Author    rw-codebundle-agent
Metadata            Display Name    Vercel Project HTTP Health SLI
Metadata            Supports    Vercel    HTTP    project    logs

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform

Suite Setup         Suite Initialization

*** Keywords ***
Suite Initialization
    TRY
        ${vercel_token}=    RW.Core.Import Secret    vercel_token
        ...    type=string
        ...    description=Vercel API bearer token with read access to project and deployment logs
        ...    pattern=\w*
        Set Suite Variable    ${vercel_token}    ${vercel_token}
    EXCEPT
        Log    vercel_token secret not found.    WARN
        Set Suite Variable    ${vercel_token}    ${EMPTY}
    END

    ${VERCEL_TEAM_ID}=    RW.Core.Import User Variable    VERCEL_TEAM_ID
    ...    type=string
    ...    description=Vercel team slug or ID; leave empty for hobby projects
    ...    pattern=^[\w-]*$
    ...    default=${EMPTY}
    ${VERCEL_PROJECT_ID}=    RW.Core.Import User Variable    VERCEL_PROJECT_ID
    ...    type=string
    ...    description=Vercel project ID (prj_...)
    ...    pattern=\w+
    ${TIME_WINDOW_HOURS}=    RW.Core.Import User Variable    TIME_WINDOW_HOURS
    ...    type=string
    ...    description=Lookback hours aligned with the runbook window
    ...    pattern=^\d+$
    ...    default=24
    ${DEPLOYMENT_ENVIRONMENT}=    RW.Core.Import User Variable    DEPLOYMENT_ENVIRONMENT
    ...    type=string
    ...    description=production, preview, or all
    ...    pattern=^(production|preview|all|Production|Preview|All)$
    ...    default=production
    ${MAX_DEPLOYMENTS_TO_SCAN}=    RW.Core.Import User Variable    MAX_DEPLOYMENTS_TO_SCAN
    ...    type=string
    ...    description=Maximum deployments considered when resolving the SLI sample deployment
    ...    pattern=^\d+$
    ...    default=10
    ${SLI_LOG_LINE_CAP}=    RW.Core.Import User Variable    SLI_LOG_LINE_CAP
    ...    type=string
    ...    description=Maximum runtime log lines read from the newest overlapping deployment for the error sample
    ...    pattern=^\d+$
    ...    default=800
    ${SLI_MAX_ERROR_EVENTS}=    RW.Core.Import User Variable    SLI_MAX_ERROR_EVENTS
    ...    type=string
    ...    description=Maximum allowed HTTP 4xx/5xx log lines in the SLI sample before scoring 0
    ...    pattern=^\d+$
    ...    default=25

    ${env}=    Create Dictionary
    ...    VERCEL_TEAM_ID=${VERCEL_TEAM_ID}
    ...    VERCEL_PROJECT_ID=${VERCEL_PROJECT_ID}
    ...    TIME_WINDOW_HOURS=${TIME_WINDOW_HOURS}
    ...    DEPLOYMENT_ENVIRONMENT=${DEPLOYMENT_ENVIRONMENT}
    ...    MAX_DEPLOYMENTS_TO_SCAN=${MAX_DEPLOYMENTS_TO_SCAN}
    ...    SLI_LOG_LINE_CAP=${SLI_LOG_LINE_CAP}
    ...    SLI_MAX_ERROR_EVENTS=${SLI_MAX_ERROR_EVENTS}
    Set Suite Variable    ${env}    ${env}
    Set Suite Variable    ${score_api}    0
    Set Suite Variable    ${score_sample}    0

*** Tasks ***
Score Vercel Project API Reachability
    [Documentation]    Binary score from GET /v9/projects for the configured project and team scope.
    [Tags]    Vercel    sli    access:read-only    data:metrics
    ${out}=    RW.CLI.Run Bash File
    ...    bash_file=sli-vercel-api-score.sh
    ...    env=${env}
    ...    secret__vercel_token=${vercel_token}
    ...    include_in_history=false
    ...    timeout_seconds=45
    TRY
        ${data}=    Evaluate    json.loads(r'''${out.stdout}''')    json
    EXCEPT
        Log    SLI API JSON parse failed; scoring 0.    WARN
        ${data}=    Create Dictionary    score=0
    END
    ${s}=    Set Variable    ${data.get('score', 0)}
    Set Suite Variable    ${score_api}    ${s}
    RW.Core.Push Metric    ${s}    sub_name=vercel_api_ok

Score Vercel Runtime Error Sample
    [Documentation]    Binary score when HTTP 4xx/5xx events in a capped runtime log sample stay at or below SLI_MAX_ERROR_EVENTS.
    [Tags]    Vercel    sli    access:read-only    data:metrics
    ${out}=    RW.CLI.Run Bash File
    ...    bash_file=sli-vercel-error-sample-score.sh
    ...    env=${env}
    ...    secret__vercel_token=${vercel_token}
    ...    include_in_history=false
    ...    timeout_seconds=90
    TRY
        ${data}=    Evaluate    json.loads(r'''${out.stdout}''')    json
    EXCEPT
        Log    SLI sample JSON parse failed; scoring 0.    WARN
        ${data}=    Create Dictionary    score=0
    END
    ${s}=    Set Variable    ${data.get('score', 0)}
    Set Suite Variable    ${score_sample}    ${s}
    RW.Core.Push Metric    ${s}    sub_name=runtime_error_sample

Generate Aggregate Vercel HTTP Health Score
    [Documentation]    Averages API reachability and error-sample sub-scores into the primary SLI metric.
    [Tags]    Vercel    sli    access:read-only    data:metrics
    ${health_score}=    Evaluate    (int(${score_api}) + int(${score_sample})) / 2.0
    ${health_score}=    Convert To Number    ${health_score}    2
    RW.Core.Add to Report    Vercel HTTP health score: ${health_score} (api=${score_api}, error_sample=${score_sample})
    RW.Core.Push Metric    ${health_score}
