*** Settings ***
Documentation       Measures Vercel project health across eight binary sub-signals — API reachability, latest production deployment READY, recent deployment failure ratio, production-branch match, latest production deployment fresh, production alias is current (no rollback in progress), production domains verified, and a capped runtime HTTP error sample. Averages them into a primary score between 0 (failing) and 1 (healthy).
Metadata            Author    rw-codebundle-agent
Metadata            Display Name    Vercel Project Health SLI
Metadata            Supports    Vercel    HTTP    project    logs

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             Vercel

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
    ...    default=
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
    ${VERCEL_REQUEST_LOGS_ENV}=    RW.Core.Import User Variable    VERCEL_REQUEST_LOGS_ENV
    ...    type=string
    ...    description=Filter passed to the historical request-logs endpoint when sampling errors. 'production' (default) scores only what real users hit.
    ...    pattern=^(production|preview|all)$
    ...    default=production
    ${SLI_LOOKBACK_HOURS}=    RW.Core.Import User Variable    SLI_LOOKBACK_HOURS
    ...    type=string
    ...    description=Lookback window (hours) for the error-sample SLI. Defaults to TIME_WINDOW_HOURS when unset.
    ...    pattern=^\d+$
    ...    default=24
    ${SLI_MAX_ROWS}=    RW.Core.Import User Variable    SLI_MAX_ROWS
    ...    type=string
    ...    description=Cap on rows fetched from the request-logs endpoint per SLI run. Bounds wall-clock for very busy projects.
    ...    pattern=^\d+$
    ...    default=200
    ${SLI_MAX_ERROR_EVENTS}=    RW.Core.Import User Variable    SLI_MAX_ERROR_EVENTS
    ...    type=string
    ...    description=Maximum allowed HTTP 4xx/5xx events in the request-logs sample before the runtime_error_sample sub-score drops to 0.
    ...    pattern=^\d+$
    ...    default=25
    ${SLI_MAX_RECENT_FAILED_DEPLOYMENTS}=    RW.Core.Import User Variable    SLI_MAX_RECENT_FAILED_DEPLOYMENTS
    ...    type=string
    ...    description=Allowed ERROR/CANCELED deployments in project.latestDeployments before the recent-failures SLI scores 0
    ...    pattern=^\d+$
    ...    default=1
    ${SLI_MAX_PRODUCTION_AGE_HOURS}=    RW.Core.Import User Variable    SLI_MAX_PRODUCTION_AGE_HOURS
    ...    type=string
    ...    description=Maximum hours since the latest production deployment before the production_deployment_fresh sub-score drops to 0 (default 168h / 7 days). Catches projects whose main branch has drifted far ahead of what is actually live.
    ...    pattern=^\d+$
    ...    default=168
    ${EXPECTED_PRODUCTION_BRANCH}=    RW.Core.Import User Variable    EXPECTED_PRODUCTION_BRANCH
    ...    type=string
    ...    description=Optional expected production branch; when set, the production-branch SLI scores 0 if Vercel's link.productionBranch differs. Leave blank to skip the check.
    ...    pattern=^[\w./-]*$
    ...    default=

    ${env}=    Create Dictionary
    ...    VERCEL_TEAM_ID=${VERCEL_TEAM_ID}
    ...    VERCEL_PROJECT_ID=${VERCEL_PROJECT_ID}
    ...    TIME_WINDOW_HOURS=${TIME_WINDOW_HOURS}
    ...    DEPLOYMENT_ENVIRONMENT=${DEPLOYMENT_ENVIRONMENT}
    ...    VERCEL_REQUEST_LOGS_ENV=${VERCEL_REQUEST_LOGS_ENV}
    ...    SLI_LOOKBACK_HOURS=${SLI_LOOKBACK_HOURS}
    ...    SLI_MAX_ROWS=${SLI_MAX_ROWS}
    ...    SLI_MAX_ERROR_EVENTS=${SLI_MAX_ERROR_EVENTS}
    ...    SLI_MAX_RECENT_FAILED_DEPLOYMENTS=${SLI_MAX_RECENT_FAILED_DEPLOYMENTS}
    ...    SLI_MAX_PRODUCTION_AGE_HOURS=${SLI_MAX_PRODUCTION_AGE_HOURS}
    ...    EXPECTED_PRODUCTION_BRANCH=${EXPECTED_PRODUCTION_BRANCH}
    Set Suite Variable    ${env}    ${env}
    Set Suite Variable    ${score_api}    0
    Set Suite Variable    ${score_sample}    0
    Set Suite Variable    ${score_prod_ready}    0
    Set Suite Variable    ${score_recent_failures}    0
    Set Suite Variable    ${score_branch}    1
    Set Suite Variable    ${score_prod_fresh}    1
    Set Suite Variable    ${score_alias_current}    1
    Set Suite Variable    ${score_domains}    1

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

Score Vercel Deployment Health Signals
    [Documentation]    Five lightweight signals derived from a single GET /v9/projects/{id} call: latest production deployment is READY; recent ERROR/CANCELED count is at or below SLI_MAX_RECENT_FAILED_DEPLOYMENTS; link.productionBranch matches EXPECTED_PRODUCTION_BRANCH (when configured); the latest production deployment is fresher than SLI_MAX_PRODUCTION_AGE_HOURS; and project.targets.production points at the newest READY production deployment (alias-current / no rollback in progress). Pushes five sub-metrics from one API call.
    [Tags]    Vercel    sli    access:read-only    data:metrics
    ${out}=    RW.CLI.Run Bash File
    ...    bash_file=sli-vercel-deployment-health-score.sh
    ...    env=${env}
    ...    secret__vercel_token=${vercel_token}
    ...    include_in_history=false
    ...    timeout_seconds=30
    TRY
        ${data}=    Evaluate    json.loads(r'''${out.stdout}''')    json
    EXCEPT
        Log    SLI deployment-health JSON parse failed; scoring 0.    WARN
        ${data}=    Create Dictionary    production_deployment_ready=0    recent_deployment_failures_ok=0    production_branch_matches=1    production_deployment_fresh=0    production_alias_current=1
    END
    ${prod_ready}=    Set Variable    ${data.get('production_deployment_ready', 0)}
    ${recent_ok}=    Set Variable    ${data.get('recent_deployment_failures_ok', 0)}
    ${branch_ok}=    Set Variable    ${data.get('production_branch_matches', 1)}
    ${prod_fresh}=    Set Variable    ${data.get('production_deployment_fresh', 1)}
    ${alias_current}=    Set Variable    ${data.get('production_alias_current', 1)}
    Set Suite Variable    ${score_prod_ready}    ${prod_ready}
    Set Suite Variable    ${score_recent_failures}    ${recent_ok}
    Set Suite Variable    ${score_branch}    ${branch_ok}
    Set Suite Variable    ${score_prod_fresh}    ${prod_fresh}
    Set Suite Variable    ${score_alias_current}    ${alias_current}
    RW.Core.Push Metric    ${prod_ready}    sub_name=production_deployment_ready
    RW.Core.Push Metric    ${recent_ok}    sub_name=recent_deployment_failures_ok
    RW.Core.Push Metric    ${branch_ok}    sub_name=production_branch_matches
    RW.Core.Push Metric    ${prod_fresh}    sub_name=production_deployment_fresh
    RW.Core.Push Metric    ${alias_current}    sub_name=production_alias_current
    ${details}=    Evaluate    ${data}.get('details', {})    json
    ${prod_uid}=    Evaluate    ${details}.get('latest_production_uid') or '-'
    ${prod_state}=    Evaluate    ${details}.get('latest_production_state') or '-'
    ${prod_age}=    Evaluate    ${details}.get('latest_production_age_hours') or '-'
    ${prod_url}=    Evaluate    ${details}.get('latest_production_url') or ''
    ${prod_branch}=    Evaluate    ${details}.get('production_branch') or '-'
    ${exp_branch}=    Evaluate    ${details}.get('expected_production_branch') or '(unset)'
    ${failed_count}=    Evaluate    ${details}.get('recent_failed_count', 0)
    ${ld_count}=    Evaluate    ${details}.get('recent_deployments_inspected', 0)
    ${fail_thr}=    Evaluate    ${details}.get('recent_failed_threshold', '-')
    ${max_age}=    Evaluate    ${details}.get('max_production_age_hours', '-')
    ${alias_id}=    Evaluate    ${details}.get('alias_deployment_id') or '-'
    ${newest_ready}=    Evaluate    ${details}.get('newest_ready_production_id') or '-'
    ${url_segment}=    Set Variable If    '${prod_url}' != ''    , https://${prod_url}    ${EMPTY}
    ${ctx}=    Set Variable    Latest production: ${prod_uid} (${prod_state}), age ${prod_age}h / max ${max_age}h${url_segment} | branch=${prod_branch}, expected=${exp_branch} | recent failed=${failed_count}/${ld_count} (threshold ${fail_thr}) | alias=${alias_id}, newest_ready=${newest_ready}
    RW.Core.Add To Report    ${ctx}

Score Vercel Domain Verification
    [Documentation]    Binary score: 1 when every production-bound domain attached to the project is verified, 0 if any production domain has verified=false. Calls GET /v9/projects/{id}/domains once per SLI run. Branch-bound preview aliases and custom-environment domains are excluded.
    [Tags]    Vercel    sli    access:read-only    data:metrics
    ${out}=    RW.CLI.Run Bash File
    ...    bash_file=sli-vercel-domains-score.sh
    ...    env=${env}
    ...    secret__vercel_token=${vercel_token}
    ...    include_in_history=false
    ...    timeout_seconds=45
    TRY
        ${data}=    Evaluate    json.loads(r'''${out.stdout}''')    json
    EXCEPT
        Log    SLI domains JSON parse failed; scoring 1 to avoid penalty.    WARN
        ${data}=    Create Dictionary    domains_verified_ok=1    reason=parse-failed    details=${EMPTY}
    END
    ${s}=    Set Variable    ${data.get('domains_verified_ok', 1)}
    Set Suite Variable    ${score_domains}    ${s}
    RW.Core.Push Metric    ${s}    sub_name=domains_verified_ok
    ${details}=    Evaluate    ${data}.get('details', {})    json
    ${total}=    Evaluate    ${details}.get('production_domains', 0)
    ${verified}=    Evaluate    ${details}.get('verified', 0)
    ${unverified_list}=    Evaluate    ${details}.get('unverified', [])
    ${unverified_count}=    Evaluate    len(${unverified_list})
    ${unverified_names}=    Evaluate    ", ".join([d.get('name','?') for d in ${unverified_list}]) or '-'
    ${ctx}=    Set Variable    Domains: production=${total}, verified=${verified}, unverified=${unverified_count} (${unverified_names})
    RW.Core.Add To Report    ${ctx}

Score Vercel Runtime Error Sample
    [Documentation]    Binary score: 1 when error-class (status >= 400) rows in a capped sample of the historical request-logs endpoint stay at or below SLI_MAX_ERROR_EVENTS, 0 otherwise. Backed by GET https://vercel.com/api/logs/request-logs (the same endpoint the dashboard's Logs page uses) — NOT the live-tail /v1/runtime-logs endpoint.
    [Tags]    Vercel    sli    access:read-only    data:metrics
    ${out}=    RW.CLI.Run Bash File
    ...    bash_file=sli-vercel-error-sample-score.sh
    ...    env=${env}
    ...    secret__vercel_token=${vercel_token}
    ...    include_in_history=false
    ...    timeout_seconds=60
    TRY
        ${data}=    Evaluate    json.loads(r'''${out.stdout}''')    json
    EXCEPT
        Log    SLI sample JSON parse failed; scoring 0.    WARN
        ${data}=    Create Dictionary    error_sample_count=999    capped=${False}    reason=parse-failed    details=${EMPTY}
    END
    ${count}=    Evaluate    int(${data}.get('error_sample_count', 0))
    ${capped}=    Evaluate    bool(${data}.get('capped', False))
    ${reason}=    Evaluate    ${data}.get('reason') or ''
    ${threshold}=    Convert To Integer    ${SLI_MAX_ERROR_EVENTS}
    ${s}=    Evaluate    1 if ${count} <= ${threshold} else 0
    Set Suite Variable    ${score_sample}    ${s}
    RW.Core.Push Metric    ${s}    sub_name=runtime_error_sample
    ${ctx}=    Set Variable    Runtime error sample: error_class_rows=${count} (threshold ${threshold}), capped=${capped}, reason=${reason}
    RW.Core.Add To Report    ${ctx}

Generate Aggregate Vercel HTTP Health Score
    [Documentation]    Averages all eight sub-scores into the primary SLI metric: API reachability, latest production deployment READY, recent deployment failure ratio OK, production-branch match, latest production deployment fresh, production alias is current (no rollback in progress), production domains verified, and runtime HTTP error sample.
    [Tags]    Vercel    sli    access:read-only    data:metrics
    ${total}=    Evaluate    int(${score_api}) + int(${score_prod_ready}) + int(${score_recent_failures}) + int(${score_branch}) + int(${score_prod_fresh}) + int(${score_alias_current}) + int(${score_domains}) + int(${score_sample})
    ${health_score}=    Evaluate    ${total} / 8.0
    ${health_score}=    Convert To Number    ${health_score}    2
    ${report_msg}=    Set Variable    Vercel project health score: ${health_score} (api=${score_api}, prod_ready=${score_prod_ready}, recent_failures_ok=${score_recent_failures}, branch_ok=${score_branch}, prod_fresh=${score_prod_fresh}, alias_current=${score_alias_current}, domains_ok=${score_domains}, error_sample=${score_sample})
    RW.Core.Add To Report    ${report_msg}
    RW.Core.Push Metric    ${health_score}
