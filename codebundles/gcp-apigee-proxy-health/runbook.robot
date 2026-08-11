*** Settings ***
Documentation       Identify and diagnose Apigee API proxy health problems: deployment state, revision drift, failed deployments, and the Apigee-specific policy_error vs target_error and latency-overhead splits.
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
Check Apigee Proxy Deployment Health in `${APIGEE_ORG}`
    [Documentation]    For each proxy deployment, verifies runtime state is READY with an empty errors[] array; flags deployments in ERROR or PROGRESSING state, or deployments reporting errors, which means the deploy did not fully take effect.
    [Tags]    gcloud    apigee    gcp    ${APIGEE_ORG}    access:read-only    data:state
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check_deployment_state.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./check_deployment_state.sh
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat deployment_state_issues.json
    ...    env=${env}
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for deployment state, defaulting to empty list.    WARN
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
    RW.Core.Add Pre To Report    Apigee Proxy Deployment Health:\n${result.stdout}

Check Apigee Deployed Revision vs Expected and Revision Drift in `${APIGEE_ORG}`
    [Documentation]    Verifies the revision deployed in each environment matches the latest available revision and that environments do not diverge for a proxy; flags stale logic live in production and environments that silently fell back to an older revision after a failed deploy.
    [Tags]    gcloud    apigee    gcp    ${APIGEE_ORG}    access:read-only    data:state
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check_revision_drift.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./check_revision_drift.sh
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat revision_drift_issues.json
    ...    env=${env}
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for revision drift, defaulting to empty list.    WARN
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
    RW.Core.Add Pre To Report    Apigee Revision Drift Analysis:\n${result.stdout}

Check Apigee Undeployed and Orphaned Proxies in `${APIGEE_ORG}`
    [Documentation]    Detects proxies that exist but are not deployed to any environment -- orphaned, or left unexposed by a deploy that never landed. Deployment ERROR state is reported by the deployment health task, not duplicated here.
    [Tags]    gcloud    apigee    gcp    ${APIGEE_ORG}    access:read-only    data:state
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check_failed_deployments.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./check_failed_deployments.sh
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat failed_deployments_issues.json
    ...    env=${env}
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for failed deployments, defaulting to empty list.    WARN
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
    RW.Core.Add Pre To Report    Apigee Undeployed Proxy Analysis:\n${result.stdout}

Check Apigee Proxy Revision Housekeeping in `${APIGEE_ORG}`
    [Documentation]    Identifies proxies accumulating many undeployed or superseded revisions without cleanup, reporting a housekeeping signal (severity 4) to prevent drift and deploy confusion over time.
    [Tags]    gcloud    apigee    gcp    ${APIGEE_ORG}    access:read-only    data:config
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check_revision_accumulation.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./check_revision_accumulation.sh
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat revision_accumulation_issues.json
    ...    env=${env}
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for revision accumulation, defaulting to empty list.    WARN
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
    RW.Core.Add Pre To Report    Apigee Revision Housekeeping:\n${result.stdout}

Analyze Apigee policy_error vs target_error Split in `${APIGEE_ORG}`
    [Documentation]    Queries Apigee Analytics (dimension apiproxy) for sum(is_error), sum(policy_error), sum(target_error), and sum(message_count), flagging proxies whose policy_error rate exceeds POLICY_ERROR_THRESHOLD (fault inside the proxy policy chain) and whose target_error rate exceeds TARGET_ERROR_THRESHOLD (backend failing), tracked separately because they route to different owners.
    [Tags]    gcloud    apigee    gcp    analytics    ${APIGEE_ORG}    access:read-only    data:metrics
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=analyze_error_split.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./analyze_error_split.sh
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat error_split_issues.json
    ...    env=${env}
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for error split, defaulting to empty list.    WARN
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
    RW.Core.Add Pre To Report    Apigee Error Split Analysis:\n${result.stdout}

Analyze Apigee Latency and Processing Overhead in `${APIGEE_ORG}`
    [Documentation]    Queries avg/percentile total_response_time and target_response_time from Analytics, flagging proxies whose p95 total_response_time exceeds LATENCY_MS_THRESHOLD and proxies whose total-minus-target gap exceeds OVERHEAD_MS_THRESHOLD (Apigee's own processing overhead, isolating a proxy-logic bottleneck from a slow backend).
    [Tags]    gcloud    apigee    gcp    analytics    ${APIGEE_ORG}    access:read-only    data:metrics
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=analyze_latency_split.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./analyze_latency_split.sh
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat latency_split_issues.json
    ...    env=${env}
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for latency split, defaulting to empty list.    WARN
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
    RW.Core.Add Pre To Report    Apigee Latency Split Analysis:\n${result.stdout}

Analyze Apigee Auth and Quota Error Elevation in `${APIGEE_ORG}`
    [Documentation]    Queries Analytics metrics by response_status_code for 401/403/429 rates, flagging elevated 401/403 (token validation failure, API product mismatch, expired developer app credentials) and elevated 429 beyond the intended quota or spike-arrest policy (rejecting legitimate traffic).
    [Tags]    gcloud    apigee    gcp    analytics    ${APIGEE_ORG}    access:read-only    data:metrics
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=analyze_http_error_rates.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./analyze_http_error_rates.sh
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat http_error_rate_issues.json
    ...    env=${env}
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for HTTP error rates, defaulting to empty list.    WARN
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
    RW.Core.Add Pre To Report    Apigee HTTP Error Rate Analysis:\n${result.stdout}

Check Apigee Failed Long-Running Operations in `${APIGEE_ORG}`
    [Documentation]    Flags management operations that failed AND left no trace in deployment state -- environment-group changes, instance changes, and deploys that failed before any deployment record existed. A failed deploy that did leave an ERROR deployment is reported by the deployment health task, not twice here. Results are not time-bounded: Apigee's operations API exposes no timestamps to filter on.
    [Tags]    gcloud    apigee    gcp    ${APIGEE_ORG}    access:read-only    data:state
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check_failed_operations.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./check_failed_operations.sh
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat failed_operations_issues.json
    ...    env=${env}
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for failed operations, defaulting to empty list.    WARN
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
    RW.Core.Add Pre To Report    Apigee Failed Operations:\n${result.stdout}

*** Keywords ***
Suite Initialization
    ${gcp_credentials}=    RW.Core.Import Secret    gcp_credentials
    ...    type=string
    ...    description=GCP service account JSON key used to authenticate with gcloud and authorize the Apigee REST API. Needs roles/apigee.readOnlyAdmin, roles/apigee.analyticsViewer, roles/monitoring.viewer.
    ...    pattern=\w*
    ...    example={"type": "service_account","project_id":"myproject-ID", ... super secret stuff ...}
    ${GCP_PROJECT_ID}=    RW.Core.Import User Variable    GCP_PROJECT_ID
    ...    type=string
    ...    description=The GCP project ID that owns the Apigee organization.
    ...    pattern=\w*
    ...    example=myproject-ID
    ${APIGEE_ORG}=    RW.Core.Import User Variable    APIGEE_ORG
    ...    type=string
    ...    description=The Apigee organization name (organizations/{org}). If empty, resolved by discovering the Apigee org(s) in GCP_PROJECT_ID.
    ...    pattern=\w*
    ...    example=my-apigee-org
    ${PROXIES}=    RW.Core.Import User Variable    PROXIES
    ...    type=string
    ...    description=Comma-separated API proxy names to scope the analysis, or 'All' for every proxy in the org.
    ...    pattern=\w*
    ...    default=All
    ${ENVIRONMENTS}=    RW.Core.Import User Variable    ENVIRONMENTS
    ...    type=string
    ...    description=Comma-separated environment names to scope deployment checks, or 'All'.
    ...    pattern=\w*
    ...    default=All
    ${POLICY_ERROR_THRESHOLD}=    RW.Core.Import User Variable    POLICY_ERROR_THRESHOLD
    ...    type=string
    ...    description=Maximum acceptable policy_error rate (0.01 = 1%). Fault inside Apigee's policy chain.
    ...    pattern=^\d*\.?\d+$
    ...    default=0.01
    ${TARGET_ERROR_THRESHOLD}=    RW.Core.Import User Variable    TARGET_ERROR_THRESHOLD
    ...    type=string
    ...    description=Maximum acceptable target_error rate (0.01 = 1%). Backend failing; hand off to backend bundle.
    ...    pattern=^\d*\.?\d+$
    ...    default=0.01
    ${LATENCY_MS_THRESHOLD}=    RW.Core.Import User Variable    LATENCY_MS_THRESHOLD
    ...    type=string
    ...    description=Maximum acceptable p95 total_response_time in milliseconds for a proxy.
    ...    pattern=^\d+$
    ...    default=5000
    ${OVERHEAD_MS_THRESHOLD}=    RW.Core.Import User Variable    OVERHEAD_MS_THRESHOLD
    ...    type=string
    ...    description=Maximum acceptable Apigee processing overhead in ms (total_response_time minus target_response_time) before proxy logic is flagged as the bottleneck.
    ...    pattern=^\d+$
    ...    default=500
    ${AUTH_ERROR_RATE_THRESHOLD}=    RW.Core.Import User Variable    AUTH_ERROR_RATE_THRESHOLD
    ...    type=string
    ...    description=Maximum acceptable 401/403 rate (0.02 = 2%) before token/product credential issues are flagged.
    ...    pattern=^\d*\.?\d+$
    ...    default=0.02
    ${RATE_LIMIT_ERROR_THRESHOLD}=    RW.Core.Import User Variable    RATE_LIMIT_ERROR_THRESHOLD
    ...    type=string
    ...    description=Maximum acceptable 429 rate (0.05 = 5%) before quota/spike-arrest rejection is flagged.
    ...    pattern=^\d*\.?\d+$
    ...    default=0.05
    ${ANALYTICS_WINDOW_MIN}=    RW.Core.Import User Variable    ANALYTICS_WINDOW_MIN
    ...    type=string
    ...    description=Analytics lookback window in minutes. Analytics lags real time (~10 min).
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

    # --- Discovery -----------------------------------------------------------
    # Discovery builds the inventory every check reads. It is setup, not a task:
    # it can only ever report its own failure, and as a task that failure showed
    # up as ONE issue while the eight dependent checks each reported "no issues
    # found" -- they had found nothing because they could not look. One honest
    # failure here is worth more than eight quiet green tasks.
    #
    # Pre-clean first: a stale inventory from an earlier run in the same working
    # directory would let a failed discovery be scored against old data.
    RW.CLI.Run Cli
    ...    cmd=rm -f apigee_topology.json apigee_deployments.json apigee_proxies.json apigee_discovery_issues.json
    ...    env=${env}
    ${discovery}=    RW.CLI.Run Bash File
    ...    bash_file=discover_proxies.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=300
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./discover_proxies.sh
    IF    $discovery.returncode != 0
        Fail    discover_proxies.sh exited ${discovery.returncode}. The inventory every check reads was not built, so no check below can report a trustworthy result.
    END

    # `status` is written on every exit path; a missing topology reads as
    # "failed", so discovery not running is never mistaken for an empty estate.
    ${status_out}=    RW.CLI.Run Cli
    ...    cmd=jq -r 'if has("status") then .status else "failed" end' apigee_topology.json 2>/dev/null || echo failed
    ...    env=${env}
    ${discovery_status}=    Set Variable    ${status_out.stdout.strip()}
    ${discovery_detail}=    RW.CLI.Run Cli
    ...    cmd=jq -r '[.[].title] | join("; ")' apigee_discovery_issues.json 2>/dev/null || echo "no detail available"
    ...    env=${env}
    IF    '${discovery_status}' == 'failed'
        Fail    Apigee discovery could not establish an inventory for project `${GCP_PROJECT_ID}`: ${discovery_detail.stdout.strip()}. Every check below would report "nothing found" against an estate it could not see, so none were run.
    END
    # INTERIM: not_applicable means this project provably has no Apigee. The
    # checks still run and correctly find nothing -- see the INTERIM note in
    # .runwhen/generation-rules/.
    IF    '${discovery_status}' == 'not_applicable'
        Log    Project ${GCP_PROJECT_ID} was determined not to use Apigee; the checks will run and report nothing.    WARN
    END
    RW.Core.Add Pre To Report    Apigee Proxy Discovery:\n${discovery.stdout}
