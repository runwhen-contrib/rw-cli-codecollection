*** Settings ***
Documentation       Measures Vercel project path-traffic health: API access, production deployment presence, and 404 share versus threshold. Produces a score between 0 (failing) and 1 (healthy).
Metadata            Author    rw-codebundle-agent
Metadata            Display Name    Vercel Project Path Traffic and Missing Routes
Metadata            Supports    Vercel vercel_project traffic observability

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             OperatingSystem

Suite Setup         Suite Initialization


*** Tasks ***
Score Vercel Path Traffic Health for Project `${VERCEL_PROJECT}`
    [Documentation]    Runs a bounded runtime log sample to compute a 0-1 health score from project access, deployment availability, and 404 share.
    [Tags]    Vercel    vercel_project    access:read-only    data:metrics
    ${out}=    RW.CLI.Run Bash File
    ...    bash_file=vercel-sli-score.sh
    ...    env=${env}
    ...    secret__vercel_api_token=${vercel_api_token}
    ...    timeout_seconds=30
    ...    include_in_history=false
    TRY
        ${m}=    Evaluate    json.loads(r'''${out.stdout}''')    json
    EXCEPT
        Log    SLI JSON parse failed, scoring 0.    WARN
        ${m}=    Create Dictionary    health=0    project_ok=0    deployment_ok=0    ratio_ok=0    details=SLI JSON parse error
    END
    ${pok}=    Convert To Number    ${m['project_ok']}
    ${dok}=    Convert To Number    ${m['deployment_ok']}
    ${rok}=    Convert To Number    ${m['ratio_ok']}
    ${h}=    Convert To Number    ${m['health']}
    RW.Core.Push Metric    ${pok}    sub_name=project_ok
    RW.Core.Push Metric    ${dok}    sub_name=deployment_ok
    RW.Core.Push Metric    ${rok}    sub_name=not_found_ratio_ok
    RW.Core.Add to Report    Vercel path traffic SLI: ${m['details']}
    RW.Core.Push Metric    ${h}


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
    ${NOT_FOUND_SPIKE_THRESHOLD_PCT}=    RW.Core.Import User Variable    NOT_FOUND_SPIKE_THRESHOLD_PCT
    ...    type=string
    ...    description=404 share threshold (percent) used in the SLI ratio check
    ...    pattern=^\d+(\.\d+)?$
    ...    default=15
    ${SPIKE_MIN_SAMPLE}=    RW.Core.Import User Variable    SPIKE_MIN_SAMPLE
    ...    type=string
    ...    description=Minimum sampled requests before applying the 404 threshold in the SLI
    ...    pattern=^\d+$
    ...    default=40
    ${LOG_SAMPLE_MAX_LINES}=    RW.Core.Import User Variable    LOG_SAMPLE_MAX_LINES
    ...    type=string
    ...    description=Maximum streamed log lines for the SLI sample
    ...    pattern=^\d+$
    ...    default=3000
    ${LOG_FETCH_MAX_SECONDS}=    RW.Core.Import User Variable    LOG_FETCH_MAX_SECONDS
    ...    type=string
    ...    description=Maximum seconds to read runtime logs in the SLI
    ...    pattern=^\d+$
    ...    default=20
    Set Suite Variable    ${vercel_api_token}    ${vercel_api_token}
    Set Suite Variable    ${VERCEL_TEAM_ID}    ${VERCEL_TEAM_ID}
    Set Suite Variable    ${VERCEL_PROJECT}    ${VERCEL_PROJECT}
    Set Suite Variable    ${LOOKBACK_MINUTES}    ${LOOKBACK_MINUTES}
    Set Suite Variable    ${NOT_FOUND_SPIKE_THRESHOLD_PCT}    ${NOT_FOUND_SPIKE_THRESHOLD_PCT}
    Set Suite Variable    ${SPIKE_MIN_SAMPLE}    ${SPIKE_MIN_SAMPLE}
    Set Suite Variable    ${LOG_SAMPLE_MAX_LINES}    ${LOG_SAMPLE_MAX_LINES}
    Set Suite Variable    ${LOG_FETCH_MAX_SECONDS}    ${LOG_FETCH_MAX_SECONDS}
    ${env}=    Create Dictionary
    ...    VERCEL_TEAM_ID=${VERCEL_TEAM_ID}
    ...    VERCEL_PROJECT=${VERCEL_PROJECT}
    ...    LOOKBACK_MINUTES=${LOOKBACK_MINUTES}
    ...    NOT_FOUND_SPIKE_THRESHOLD_PCT=${NOT_FOUND_SPIKE_THRESHOLD_PCT}
    ...    SPIKE_MIN_SAMPLE=${SPIKE_MIN_SAMPLE}
    ...    LOG_SAMPLE_MAX_LINES=${LOG_SAMPLE_MAX_LINES}
    ...    LOG_FETCH_MAX_SECONDS=${LOG_FETCH_MAX_SECONDS}
    Set Suite Variable    ${env}    ${env}
