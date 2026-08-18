*** Settings ***
Documentation       Monitor the runtime traffic, performance, and reliability of Apigee API proxying via Cloud Monitoring, flagging elevated error/fault rates, high latency percentiles, throughput anomalies, and degraded target/backend behavior.
Metadata            Author    rw-codebundle-agent
Metadata            Display Name    GCP Apigee Traffic and Performance Health
Metadata            Supports    GCP,Apigee,API Management,Traffic Monitoring
Force Tags          GCP    Apigee    API Management    Traffic Monitoring

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             OperatingSystem
Library             Collections

Suite Setup         Suite Initialization

*** Tasks ***
Check Apigee API Error and Fault Rates in `${APIGEE_ORG}`
    [Documentation]    Queries proxy-level proxyv2 request/response counts and server fault_count metrics over the window to compute error/fault rates, raising one finding that lists every proxy whose 5xx or fault rate exceeds ERROR_RATE_THRESHOLD.
    [Tags]    gcloud    apigee    monitoring    gcp    ${GCP_PROJECT_ID}    access:read-only    data:metrics
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check_error_rates.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./check_error_rates.sh
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat error_rate_issues.json
    ...    env=${env}
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for error rates, defaulting to empty list.    WARN
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
    RW.Core.Add Pre To Report    Apigee Error and Fault Rate Analysis:\n${result.stdout}

Check Apigee API Latency Performance in `${APIGEE_ORG}`
    [Documentation]    Queries proxyv2/percentile latency metrics and raises one finding that lists every proxy whose p95 latency exceeds LATENCY_MS_THRESHOLD, indicating slow APIs.
    [Tags]    gcloud    apigee    monitoring    gcp    ${GCP_PROJECT_ID}    access:read-only    data:metrics
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check_latency.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./check_latency.sh
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat latency_issues.json
    ...    env=${env}
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for latency, defaulting to empty list.    WARN
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
    RW.Core.Add Pre To Report    Apigee Latency Performance Analysis:\n${result.stdout}

Check Apigee Throughput and Anomalies in `${APIGEE_ORG}`
    [Documentation]    Reviews request/response volume and the environment/anomaly_count metric, raising one finding per failure mode that lists every environment with anomalous traffic (spikes or drops) that may indicate an incident, a mis-route, or a dead backend.
    [Tags]    gcloud    apigee    monitoring    gcp    ${GCP_PROJECT_ID}    access:read-only    data:metrics
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check_throughput.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./check_throughput.sh
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat throughput_issues.json
    ...    env=${env}
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for throughput and anomalies, defaulting to empty list.    WARN
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
    RW.Core.Add Pre To Report    Apigee Throughput and Anomaly Analysis:\n${result.stdout}

Check Apigee Target and Backend Performance in `${APIGEE_ORG}`
    [Documentation]    Queries target/upstream request and response metrics to detect slow or failing backend target servers, raising one finding that lists every target whose error rate exceeds ERROR_RATE_THRESHOLD.
    [Tags]    gcloud    apigee    monitoring    gcp    ${GCP_PROJECT_ID}    access:read-only    data:metrics
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check_target_performance.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./check_target_performance.sh
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat target_performance_issues.json
    ...    env=${env}
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for target performance, defaulting to empty list.    WARN
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
    RW.Core.Add Pre To Report    Apigee Target and Backend Performance Analysis:\n${result.stdout}

*** Keywords ***
Suite Initialization
    ${gcp_credentials}=    RW.Core.Import Secret    gcp_credentials
    ...    type=string
    ...    description=GCP service account json used to authenticate with GCP APIs and Cloud Monitoring.
    ...    pattern=\w*
    ...    example={"type": "service_account","project_id":"myproject-ID", ... super secret stuff ...}
    ${APIGEE_ORG}=    RW.Core.Import User Variable    APIGEE_ORG
    ...    type=string
    ...    description=The Apigee organization name that scopes which proxies, environments, and target servers are evaluated. Supplied by the SLX, which is generated from the indexed organization.
    ...    pattern=\w*
    ...    example=my-apigee-org
    ${GCP_PROJECT_ID}=    RW.Core.Import User Variable    GCP_PROJECT_ID
    ...    type=string
    ...    description=The GCP Project ID that hosts the Apigee runtime and is the Cloud Monitoring scope for metric queries.
    ...    pattern=\w*
    ...    example=myproject-ID
    ${ERROR_RATE_THRESHOLD}=    RW.Core.Import User Variable    ERROR_RATE_THRESHOLD
    ...    type=string
    ...    description=Error/fault rate (percent of requests returning 5xx or faults) above which a proxy is flagged.
    ...    pattern=^\d*\.?\d+$
    ...    default=5
    ${LATENCY_MS_THRESHOLD}=    RW.Core.Import User Variable    LATENCY_MS_THRESHOLD
    ...    type=string
    ...    description=p95 latency in milliseconds above which a proxy is flagged as slow.
    ...    pattern=^\d+$
    ...    default=500
    ${METRIC_WINDOW_MIN}=    RW.Core.Import User Variable    METRIC_WINDOW_MIN
    ...    type=string
    ...    description=Lookback window in minutes for the Cloud Monitoring metric queries.
    ...    pattern=^\d+$
    ...    default=60
    ${THROUGHPUT_DEVIATION_PCT}=    RW.Core.Import User Variable    THROUGHPUT_DEVIATION_PCT
    ...    type=string
    ...    description=Deviation band for request volume against the previous window, read as a factor - 200 means "tripled, or fell to under a third".
    ...    pattern=^\d+$
    ...    default=200
    Set Suite Variable    ${gcp_credentials}    ${gcp_credentials}
    Set Suite Variable    ${APIGEE_ORG}    ${APIGEE_ORG}
    Set Suite Variable    ${GCP_PROJECT_ID}    ${GCP_PROJECT_ID}
    Set Suite Variable    ${ERROR_RATE_THRESHOLD}    ${ERROR_RATE_THRESHOLD}
    Set Suite Variable    ${LATENCY_MS_THRESHOLD}    ${LATENCY_MS_THRESHOLD}
    Set Suite Variable    ${METRIC_WINDOW_MIN}    ${METRIC_WINDOW_MIN}
    Set Suite Variable    ${THROUGHPUT_DEVIATION_PCT}    ${THROUGHPUT_DEVIATION_PCT}
    ${OS_PATH}=    Get Environment Variable    PATH
    Set Suite Variable
    ...    ${env}
    ...    {"CLOUDSDK_CORE_PROJECT":"${GCP_PROJECT_ID}","PATH":"$PATH:${OS_PATH}","APIGEE_ORG":"${APIGEE_ORG}","GCP_PROJECT_ID":"${GCP_PROJECT_ID}","ERROR_RATE_THRESHOLD":"${ERROR_RATE_THRESHOLD}","LATENCY_MS_THRESHOLD":"${LATENCY_MS_THRESHOLD}","METRIC_WINDOW_MIN":"${METRIC_WINDOW_MIN}","THROUGHPUT_DEVIATION_PCT":"${THROUGHPUT_DEVIATION_PCT}"}
    # Activation is best-effort. The runner may already carry a usable identity
    # (workload identity), in which case a failed activation is cosmetic -- which
    # is why the other GCP bundles in this collection all suffix this call with
    # `|| true`. Gating the suite on the activation's exit code turned that
    # cosmetic failure into a total outage: every task reported NOT RUN.
    ${auth}=    RW.CLI.Run CLI
    ...    cmd=gcloud auth activate-service-account --key-file="./${gcp_credentials.key}" || true
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}

    # Determine the key file's SHAPE rather than inferring it from the activation
    # error. "Missing required argument [ACCOUNT]: An account is required when
    # using .p12 keys" does not mean the key is a p12 -- it means gcloud's
    # json.load() failed and it fell back to assuming one. That single error
    # covers an absent file, an empty file, and a file whose contents are not
    # JSON at all (a base64-encoded key stored without being decoded is the
    # usual cause), which are three different things to go fix.
    #
    # Emits a sentinel only. No byte of the key is echoed, logged or put in an
    # issue -- the shape is the diagnostic, the contents are not.
    ${keyshape}=    RW.CLI.Run CLI
    ...    cmd=f="./${gcp_credentials.key}"; if [ ! -f "$f" ]; then echo KEY_MISSING; elif [ ! -s "$f" ]; then echo KEY_EMPTY; elif [ "$(head -c 512 "$f" | tr -d '[:space:]' | cut -c1)" = "{" ]; then echo KEY_JSON; else echo KEY_NOT_JSON; fi
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    Log    gcp_credentials key file shape: ${keyshape.stdout}

    # This check is NOT tolerant, and it is the one that matters. Assert the
    # capability every downstream gcloud and curl call actually depends on -- can
    # a token be minted -- rather than the mechanism that usually supplies it.
    # With no token, those calls run as no identity at all, every metric query
    # comes back empty, and an org with no visible traffic reports as healthy.
    ${token}=    RW.CLI.Run CLI
    ...    cmd=gcloud auth print-access-token >/dev/null 2>&1 && echo TOKEN_OK || echo TOKEN_ABSENT
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    IF    "TOKEN_ABSENT" in """${token.stdout}"""
        RW.Core.Add Issue
        ...    severity=1
        ...    expected=An access token should be obtainable, whether from the gcp_credentials key or from an ambient runner identity.
        ...    actual=No access token could be minted, so no Apigee or Cloud Monitoring call in this run can be trusted.
        ...    title=Cannot authenticate to GCP with the supplied credentials
        ...    reproduce_hint=gcloud auth activate-service-account --key-file=<gcp_credentials> && gcloud auth print-access-token
        ...    details=gcp_credentials key file shape: ${keyshape.stdout}\n(KEY_JSON = well-formed, so suspect the key's contents or IAM; KEY_NOT_JSON = not JSON at all, commonly a base64-encoded key stored without decoding; KEY_EMPTY / KEY_MISSING = the secret did not reach the runner.)\n\nactivate-service-account stderr:\n${auth.stderr}\n\nprint-access-token stderr:\n${token.stderr}
        ...    next_steps=Verify the gcp_credentials secret contains a valid, non-expired service account JSON key for project ${GCP_PROJECT_ID}, stored as raw JSON rather than base64.
        Fail    Could not obtain a GCP access token; not attempting any check.
    END

    # Discovery runs here, not as a task. It builds the metric scope every check
    # reads and can raise no finding about Apigee itself -- only about its own
    # ability to run. As a task it also produced a dishonest task list: when
    # discovery failed, all four checks still ran against an empty scope, found
    # nothing and rendered as passed, which is indistinguishable from a healthy
    # org. Failing setup means they are not attempted instead.
    ${discovery}=    RW.CLI.Run Bash File
    ...    bash_file=discover_metrics_scope.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./discover_metrics_scope.sh
    RW.Core.Add Pre To Report    Apigee Metrics Scope Discovery:\n${discovery.stdout}

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat discovery_issues.json 2>/dev/null || echo '[]'
    ...    env=${env}
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        # Unparseable output means discovery did not complete cleanly. Defaulting
        # to an empty list here would drop the failure entirely, so treat it as
        # one.
        Log    discovery_issues.json could not be parsed; treating discovery as failed.    WARN
        ${issue_list}=    Create List    ${{ {'severity': 2, 'title': 'Apigee metric scope discovery produced unreadable output', 'expected': 'discovery_issues.json should be valid JSON.', 'actual': 'discovery_issues.json was missing or unparseable.', 'details': r'''${issues.stdout}''', 'next_steps': 'Re-run discover_metrics_scope.sh directly and inspect its output.'} }}
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=${issue['expected']}
            ...    actual=${issue['actual']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${discovery.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
        Fail    Apigee metric scope discovery failed; not attempting any check against an unread scope.
    END

    # APIGEE_ORG arrives already populated: the generation rule gates on
    # gcp_apigee_organizations, so the matched resource IS the organization and
    # the SLX supplies its name at render time. Nothing to resolve here. Task
    # names are substituted from config_provided rather than from Robot suite
    # variables, so resolving it here could not name the tasks anyway.
