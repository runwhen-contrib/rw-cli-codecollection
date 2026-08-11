*** Settings ***
Documentation       Scores GCP Apigee API proxy health as a 0-1 value averaged across three fast management-API dimensions: deployment state, revision drift, and failed/undeployed proxies.
Metadata            Author    rw-codebundle-agent
Metadata            Display Name    GCP Apigee API Proxy Deployment and Traffic Health
Metadata            Supports    GCP,Apigee,API Proxy,Health
Force Tags          GCP    Apigee    API Proxy    Health

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             OperatingSystem
Library             Collections

Suite Setup         Suite Initialization

*** Tasks ***
Establish Apigee Discovery Baseline for `${APIGEE_ORG}`
    [Documentation]    Resolves the Apigee org and caches deployments/proxies. A run that cannot authenticate, cannot resolve the org, or cannot read deployment status reports a discovery issue, which forces every sub-score AND the aggregate to 0 -- a blind run must never be indistinguishable from a healthy one.
    [Tags]    gcloud    apigee    gcp    ${APIGEE_ORG}    data:config    access:read-only
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=discover_proxies.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=300
    # INTERIM (remove when the rule gates on gcp_apigee_organizations):
    # the generation rule matches every project, so this SLX may be pointed at a
    # project that has never used Apigee. Discovery sets applicable=false ONLY on
    # a definite answer -- never on a failed lookup -- so this cannot resurrect
    # healthy-while-blind scoring. `has()` rather than `.applicable // "true"`:
    # `//` falls through on false as well as null, so a correctly-set false
    # would read as the default.
    ${applicable_output}=    RW.CLI.Run Cli
    ...    cmd=jq -r 'if has("applicable") then (.applicable | tostring) else "true" end' apigee_topology.json 2>/dev/null || echo true
    ...    env=${env}
    ${applicable}=    Evaluate    0 if """${applicable_output.stdout}""".strip() == "false" else 1
    Set Suite Variable    ${applicable}
    RW.Core.Push Metric    ${applicable}    sub_name=apigee_present

    # A MISSING file means discovery never completed, so it defaults to 1 issue
    # (not 0). Defaulting to 0 here is what makes an unrunnable check score green.
    ${discovery_output}=    RW.CLI.Run Cli
    ...    cmd=jq 'length' apigee_discovery_issues.json 2>/dev/null || echo 1
    ...    env=${env}
    ${discovery_issue_count}=    Evaluate    int(${discovery_output.stdout or 1})
    ${discovery_ok}=    Evaluate    1 if ${discovery_issue_count} == 0 else 0
    Set Suite Variable    ${discovery_ok}
    RW.Core.Push Metric    ${discovery_ok}    sub_name=discovery_ok

Score Apigee Proxy Deployment State in `${APIGEE_ORG}`
    [Documentation]    Scores 1.0 if every proxy deployment is READY with an empty errors[] array, 0.0 otherwise or if discovery could not run.
    [Tags]    gcloud    apigee    gcp    ${APIGEE_ORG}    data:state    access:read-only
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check_deployment_state.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    # A check that crashed leaves whatever file was there before it. Scoring
    # that is scoring a stale result, so refuse rather than guess.
    IF    $result.returncode != 0
        Fail    check_deployment_state.sh exited ${result.returncode}. The check did not complete, so any output present is stale from an earlier run. Refusing to report a result for a check that failed.
    END
    ${issues_output}=    RW.CLI.Run Cli
    ...    cmd=jq length deployment_state_issues.json 2>/dev/null || echo -1
    ...    env=${env}
    ${dep_count}=    Evaluate    int(${issues_output.stdout or -1})
    ${measured_out}=    RW.CLI.Run Cli
    ...    cmd=cat deployment_state_measured 2>/dev/null || echo MISSING
    ...    env=${env}
    ${measured}=    Set Variable    ${measured_out.stdout.strip()}
    IF    ${applicable} == 0
        ${dep_score}=    Set Variable    ${1}
    ELSE IF    ${discovery_ok} == 0
        ${dep_score}=    Set Variable    ${0}
        RW.Core.Push Metric    ${0}    sub_name=deployment_state
    ELSE IF    '${measured}' == 'MISSING'
        Fail    check_deployment_state.sh did not report whether it measured anything. Refusing to score a dimension of unknown provenance.
    ELSE IF    '${measured}' == 'false'
        ${dep_score}=    Set Variable    unmeasured
        Log    No deployments in scope; reporting deployment state as unmeasured rather than healthy.    WARN
    ELSE
        ${dep_score}=    Evaluate    1 if (${discovery_ok} == 1 and ${dep_count} == 0) else 0
        RW.Core.Push Metric    ${dep_score}    sub_name=deployment_state
    END
    Set Suite Variable    ${dep_score}
    RW.Core.Push Metric    ${{max(${dep_count}, 0)}}    sub_name=bad_deployment_count

Score Apigee Revision Drift in `${APIGEE_ORG}`
    [Documentation]    Scores 1.0 if every proxy is on its latest revision across all environments with no cross-environment drift, 0.0 otherwise or if discovery could not run.
    [Tags]    gcloud    apigee    gcp    ${APIGEE_ORG}    data:state    access:read-only
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check_revision_drift.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    IF    $result.returncode != 0
        Fail    check_revision_drift.sh exited ${result.returncode}. The check did not complete, so any output present is stale from an earlier run. Refusing to report a result for a check that failed.
    END
    ${issues_output}=    RW.CLI.Run Cli
    ...    cmd=jq length revision_drift_issues.json 2>/dev/null || echo -1
    ...    env=${env}
    ${drift_count}=    Evaluate    int(${issues_output.stdout or -1})
    ${measured_out}=    RW.CLI.Run Cli
    ...    cmd=cat revision_drift_measured 2>/dev/null || echo MISSING
    ...    env=${env}
    ${measured}=    Set Variable    ${measured_out.stdout.strip()}
    IF    ${applicable} == 0
        ${drift_score}=    Set Variable    ${1}
    ELSE IF    ${discovery_ok} == 0
        ${drift_score}=    Set Variable    ${0}
        RW.Core.Push Metric    ${0}    sub_name=revision_drift
    ELSE IF    '${measured}' == 'MISSING'
        Fail    check_revision_drift.sh did not report whether it measured anything. Refusing to score a dimension of unknown provenance.
    ELSE IF    '${measured}' == 'false'
        ${drift_score}=    Set Variable    unmeasured
        Log    No deployments in scope; reporting revision drift as unmeasured rather than healthy.    WARN
    ELSE
        ${drift_score}=    Evaluate    1 if (${discovery_ok} == 1 and ${drift_count} == 0) else 0
        RW.Core.Push Metric    ${drift_score}    sub_name=revision_drift
    END
    Set Suite Variable    ${drift_score}
    RW.Core.Push Metric    ${{max(${drift_count}, 0)}}    sub_name=drift_issue_count

Score Apigee Failed and Undeployed Proxies in `${APIGEE_ORG}`
    [Documentation]    Scores 1.0 if no deployments failed and every proxy is deployed to at least one environment, 0.0 otherwise or if discovery could not run.
    [Tags]    gcloud    apigee    gcp    ${APIGEE_ORG}    data:state    access:read-only
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check_failed_deployments.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    IF    $result.returncode != 0
        Fail    check_failed_deployments.sh exited ${result.returncode}. The check did not complete, so any output present is stale from an earlier run. Refusing to report a result for a check that failed.
    END
    ${issues_output}=    RW.CLI.Run Cli
    ...    cmd=jq length failed_deployments_issues.json 2>/dev/null || echo -1
    ...    env=${env}
    ${fail_count}=    Evaluate    int(${issues_output.stdout or -1})
    ${measured_out}=    RW.CLI.Run Cli
    ...    cmd=cat failed_deployments_measured 2>/dev/null || echo MISSING
    ...    env=${env}
    ${measured}=    Set Variable    ${measured_out.stdout.strip()}
    IF    ${applicable} == 0
        ${fail_score}=    Set Variable    ${1}
    ELSE IF    ${discovery_ok} == 0
        ${fail_score}=    Set Variable    ${0}
        RW.Core.Push Metric    ${0}    sub_name=failed_deployments
    ELSE IF    '${measured}' == 'MISSING'
        Fail    check_failed_deployments.sh did not report whether it measured anything. Refusing to score a dimension of unknown provenance.
    ELSE IF    '${measured}' == 'false'
        ${fail_score}=    Set Variable    unmeasured
        Log    No proxies in scope; reporting failed/undeployed proxies as unmeasured rather than healthy.    WARN
    ELSE
        ${fail_score}=    Evaluate    1 if (${discovery_ok} == 1 and ${fail_count} == 0) else 0
        RW.Core.Push Metric    ${fail_score}    sub_name=failed_deployments
    END
    Set Suite Variable    ${fail_score}
    RW.Core.Push Metric    ${{max(${fail_count}, 0)}}    sub_name=failed_undeployed_count

Generate Aggregate Apigee Health Score for `${APIGEE_ORG}`
    [Documentation]    Averages the three dimension sub-scores into the final 0-1 health score. A discovery failure forces the aggregate to 0, matching every sub-score. A project determined not to use Apigee scores 1.0 by vacuity and is identified by the apigee_present sub-metric.
    [Tags]    gcloud    apigee    gcp    ${APIGEE_ORG}    data:metrics    access:read-only
    # A failed check never reaches its `Set Suite Variable`, so its score is
    # simply undefined here. Reading it directly raises "Variable not found",
    # which buries the real failure under a confusing secondary error. Collect
    # what is missing and say so plainly instead.
    ${missing}=    Create List
    ${dep_score}=      Get Variable Value    ${dep_score}      ${None}
    ${drift_score}=    Get Variable Value    ${drift_score}    ${None}
    ${fail_score}=     Get Variable Value    ${fail_score}     ${None}
    IF    $dep_score is None      Append To List    ${missing}    deployment state
    IF    $drift_score is None    Append To List    ${missing}    revision drift
    IF    $fail_score is None     Append To List    ${missing}    failed/undeployed proxies
    IF    len(${missing}) > 0
        ${missing_csv}=    Evaluate    ", ".join($missing)
        Fail    Cannot compute an aggregate health score: ${missing_csv} did not produce a sub-score because the underlying check failed. Scoring from the remaining dimensions would understate the failure. Fix the failing check(s) above.
    END

    # One IF/ELSE chain rather than early returns: `RETURN` is only valid inside
    # a user keyword, not in a task body.
    #
    # Order is load-bearing. Discovery failure is evaluated BEFORE the unmeasured
    # logic and dominates it: a run that could not see the org also leaves every
    # dimension unmeasured, and that must score 0 (we know nothing) rather than
    # raise "nothing to judge" (which claims we looked and the org was empty).
    IF    ${applicable} == 0
        # INTERIM: this branch goes away with the generation-rule gate.
        ${health_score}=    Convert to Number    ${1}    2
        RW.Core.Add to Report    Apigee Proxy Health Score: ${health_score} -- project `${GCP_PROJECT_ID}` was determined NOT to use Apigee, so there is nothing to report on. This is vacuously healthy, not verified healthy: filter on the apigee_present sub-metric (0) to exclude these projects.
    ELSE IF    ${discovery_ok} == 0
        ${health_score}=    Convert to Number    ${0}    2
        RW.Core.Add to Report    Apigee Proxy Health Score: ${health_score} -- discovery failed, so nothing about `${APIGEE_ORG}` could be established. See the discovery issue above.
    ELSE
        # A dimension reported as `unmeasured` had nothing to judge -- typically
        # an org with no proxies deployed. Averaging it in as 1.0 would hand an
        # empty org the same score as a flawless one, which is the
        # did-not-measure-equals-healthy conflation this bundle refuses to make
        # everywhere else. Drop it and renormalise over what was measured.
        ${total}=    Set Variable    ${0}
        ${counted}=    Set Variable    ${0}
        ${unmeasured}=    Create List
        FOR    ${name}    ${score}    IN
        ...    deployment state             ${dep_score}
        ...    revision drift               ${drift_score}
        ...    failed/undeployed proxies    ${fail_score}
            IF    '${score}' == 'unmeasured'
                Append To List    ${unmeasured}    ${name}
            ELSE
                ${total}=    Evaluate    ${total} + ${score}
                ${counted}=    Evaluate    ${counted} + 1
            END
        END
        IF    ${counted} == 0
            Fail    Apigee organization `${APIGEE_ORG}` is reachable but contains nothing to evaluate -- no proxies and no deployments. There is no proxy health to report. This is NOT a healthy result: deploy a proxy, or scope this SLX to an org that serves traffic.
        END
        ${health_score}=    Evaluate    ${total} / ${counted}
        ${health_score}=    Convert to Number    ${health_score}    2
        IF    len(${unmeasured}) > 0
            ${unmeasured_csv}=    Evaluate    ", ".join($unmeasured)
            RW.Core.Add to Report    NOTE: ${unmeasured_csv} had nothing to judge and were excluded from the score (averaged over ${counted} dimension(s)). The score reflects only what was measured.
        END
        RW.Core.Add to Report    Apigee Proxy Health Score: ${health_score} -- apigee_present: ${applicable}, discovery_ok: ${discovery_ok}, deployment_state: ${dep_score}, revision_drift: ${drift_score}, failed_deployments: ${fail_score}
    END
    RW.Core.Push Metric    ${health_score}

*** Keywords ***
Suite Initialization
    ${gcp_credentials}=    RW.Core.Import Secret    gcp_credentials
    ...    type=string
    ...    description=GCP service account JSON key used to authenticate with gcloud and authorize the Apigee REST API. Needs roles/apigee.readOnlyAdmin.
    ...    pattern=\w*
    ...    example={"type": "service_account","project_id":"myproject-ID", ... super secret stuff ...}
    ${GCP_PROJECT_ID}=    RW.Core.Import User Variable    GCP_PROJECT_ID
    ...    type=string
    ...    description=The GCP project ID that owns the Apigee organization.
    ...    pattern=\w*
    ...    example=myproject-ID
    ${APIGEE_ORG}=    RW.Core.Import User Variable    APIGEE_ORG
    ...    type=string
    ...    description=The Apigee organization name (organizations/{org}). If empty, resolved from GCP_PROJECT_ID.
    ...    pattern=\w*
    ...    example=my-apigee-org
    ${PROXIES}=    RW.Core.Import User Variable    PROXIES
    ...    type=string
    ...    description=Comma-separated API proxy names to scope, or 'All'.
    ...    pattern=\w*
    ...    default=All
    ${ENVIRONMENTS}=    RW.Core.Import User Variable    ENVIRONMENTS
    ...    type=string
    ...    description=Comma-separated environment names to scope, or 'All'.
    ...    pattern=\w*
    ...    default=All
    ${POLICY_ERROR_THRESHOLD}=    RW.Core.Import User Variable    POLICY_ERROR_THRESHOLD
    ...    type=string
    ...    description=Maximum acceptable policy_error rate (0.01 = 1%).
    ...    pattern=^\d*\.?\d+$
    ...    default=0.01
    ${TARGET_ERROR_THRESHOLD}=    RW.Core.Import User Variable    TARGET_ERROR_THRESHOLD
    ...    type=string
    ...    description=Maximum acceptable target_error rate (0.01 = 1%).
    ...    pattern=^\d*\.?\d+$
    ...    default=0.01
    ${LATENCY_MS_THRESHOLD}=    RW.Core.Import User Variable    LATENCY_MS_THRESHOLD
    ...    type=string
    ...    description=Maximum acceptable p95 total_response_time in ms.
    ...    pattern=^\d+$
    ...    default=5000
    ${OVERHEAD_MS_THRESHOLD}=    RW.Core.Import User Variable    OVERHEAD_MS_THRESHOLD
    ...    type=string
    ...    description=Maximum acceptable Apigee processing overhead in ms.
    ...    pattern=^\d+$
    ...    default=500
    ${AUTH_ERROR_RATE_THRESHOLD}=    RW.Core.Import User Variable    AUTH_ERROR_RATE_THRESHOLD
    ...    type=string
    ...    description=Maximum acceptable 401/403 rate.
    ...    pattern=^\d*\.?\d+$
    ...    default=0.02
    ${RATE_LIMIT_ERROR_THRESHOLD}=    RW.Core.Import User Variable    RATE_LIMIT_ERROR_THRESHOLD
    ...    type=string
    ...    description=Maximum acceptable 429 rate.
    ...    pattern=^\d*\.?\d+$
    ...    default=0.05
    ${ANALYTICS_WINDOW_MIN}=    RW.Core.Import User Variable    ANALYTICS_WINDOW_MIN
    ...    type=string
    ...    description=Analytics lookback window in minutes.
    ...    pattern=^\d+$
    ...    default=60
    ${APIGEE_MAX_STATUS_CALLS}=    RW.Core.Import User Variable    APIGEE_MAX_STATUS_CALLS
    ...    type=string
    ...    description=Maximum per-deployment runtime-status calls discovery may make. Deployments beyond this cap are reported as UNKNOWN, never as healthy.
    ...    pattern=^\d+$
    ...    default=250
    ${REVISION_ACCUMULATION_THRESHOLD}=    RW.Core.Import User Variable    REVISION_ACCUMULATION_THRESHOLD
    ...    type=string
    ...    description=Number of total revisions at which a proxy is flagged for housekeeping.
    ...    pattern=^\d+$
    ...    default=20
    Set Suite Variable    ${GCP_PROJECT_ID}    ${GCP_PROJECT_ID}
    Set Suite Variable    ${gcp_credentials}    ${gcp_credentials}
    Set Suite Variable    ${APIGEE_ORG}    ${APIGEE_ORG}
    Set Suite Variable    ${PROXIES}    ${PROXIES}
    Set Suite Variable    ${ENVIRONMENTS}    ${ENVIRONMENTS}
    Set Suite Variable    ${POLICY_ERROR_THRESHOLD}    ${POLICY_ERROR_THRESHOLD}
    Set Suite Variable    ${TARGET_ERROR_THRESHOLD}    ${TARGET_ERROR_THRESHOLD}
    Set Suite Variable    ${LATENCY_MS_THRESHOLD}    ${LATENCY_MS_THRESHOLD}
    Set Suite Variable    ${OVERHEAD_MS_THRESHOLD}    ${OVERHEAD_MS_THRESHOLD}
    Set Suite Variable    ${AUTH_ERROR_RATE_THRESHOLD}    ${AUTH_ERROR_RATE_THRESHOLD}
    Set Suite Variable    ${RATE_LIMIT_ERROR_THRESHOLD}    ${RATE_LIMIT_ERROR_THRESHOLD}
    Set Suite Variable    ${ANALYTICS_WINDOW_MIN}    ${ANALYTICS_WINDOW_MIN}
    Set Suite Variable    ${APIGEE_MAX_STATUS_CALLS}    ${APIGEE_MAX_STATUS_CALLS}
    Set Suite Variable    ${REVISION_ACCUMULATION_THRESHOLD}    ${REVISION_ACCUMULATION_THRESHOLD}
    ${OS_PATH}=    Get Environment Variable    PATH
    Set Suite Variable
    ...    ${env}
    ...    {"CLOUDSDK_CORE_PROJECT":"${GCP_PROJECT_ID}","PATH":"$PATH:${OS_PATH}","GCP_PROJECT_ID":"${GCP_PROJECT_ID}","APIGEE_ORG":"${APIGEE_ORG}","PROXIES":"${PROXIES}","ENVIRONMENTS":"${ENVIRONMENTS}","POLICY_ERROR_THRESHOLD":"${POLICY_ERROR_THRESHOLD}","TARGET_ERROR_THRESHOLD":"${TARGET_ERROR_THRESHOLD}","LATENCY_MS_THRESHOLD":"${LATENCY_MS_THRESHOLD}","OVERHEAD_MS_THRESHOLD":"${OVERHEAD_MS_THRESHOLD}","AUTH_ERROR_RATE_THRESHOLD":"${AUTH_ERROR_RATE_THRESHOLD}","RATE_LIMIT_ERROR_THRESHOLD":"${RATE_LIMIT_ERROR_THRESHOLD}","ANALYTICS_WINDOW_MIN":"${ANALYTICS_WINDOW_MIN}","APIGEE_MAX_STATUS_CALLS":"${APIGEE_MAX_STATUS_CALLS}","REVISION_ACCUMULATION_THRESHOLD":"${REVISION_ACCUMULATION_THRESHOLD}"}
    RW.CLI.Run CLI
    ...    cmd=gcloud auth activate-service-account --key-file="./${gcp_credentials.key}" || true
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
