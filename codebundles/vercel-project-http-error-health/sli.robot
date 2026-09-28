*** Settings ***
Documentation       Measures Vercel HTTP health for a project by scoring 5xx and 4xx error rates from sampled runtime logs. Produces a value between 0 (failing) and 1 (healthy).
Metadata            Author    rw-codebundle-agent
Metadata            Display Name    Vercel Project HTTP Error Health
Metadata            Supports    Vercel vercel_project HTTP SLI
Force Tags          Vercel    vercel_project    HTTP    SLI

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform

Suite Setup         Suite Initialization


*** Tasks ***
Score Vercel 5xx and 4xx Health for Project `${VERCEL_PROJECT}`
    [Documentation]    Fetches a lightweight sample of runtime logs for the production deployment and emits binary sub-scores plus an aggregate mean between 0 and 1.
    [Tags]    Vercel    access:read-only    data:metrics

    ${snap}=    RW.CLI.Run Bash File
    ...    bash_file=vercel-sli-health.sh
    ...    env=${env}
    ...    secret__VERCEL_API_TOKEN=${vercel_api_token}
    ...    timeout_seconds=60
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=false
    ...    cmd_override=./vercel-sli-health.sh

    TRY
        ${m}=    Evaluate    json.loads(r'''${snap.stdout}''')    json
        ${s5}=    Convert To Number    ${m['score_5xx']}
        ${s4}=    Convert To Number    ${m['score_4xx']}
        ${agg}=    Convert To Number    ${m['aggregate']}
    EXCEPT
        Log    SLI JSON parse failed; scoring 0.    WARN
        ${s5}=    Convert To Number    0
        ${s4}=    Convert To Number    0
        ${agg}=    Convert To Number    0
    END

    RW.Core.Push Metric    ${s5}    sub_name=score_5xx
    RW.Core.Push Metric    ${s4}    sub_name=score_4xx
    RW.Core.Push Metric    ${agg}
    RW.Core.Add to Report    Vercel HTTP SLI aggregate=${agg} (${snap.stdout})


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
    ...    description=Minimum error events before treating a high rate as failing.
    ...    pattern=^\d+$
    ...    default=5

    ${EXCLUDE_404_FROM_4XX}=    RW.Core.Import User Variable    EXCLUDE_404_FROM_4XX
    ...    type=string
    ...    description=If true, exclude HTTP 404 from 4xx scoring.
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
