*** Settings ***
Documentation       Evaluates PgBouncer connection pool health using Prometheus metrics from the community pgbouncer exporter, with optional kubectl validation of pool mode.
Metadata            Author    rw-codebundle-agent
Metadata            Display Name    Kubernetes PgBouncer Prometheus Health
Metadata            Supports    Kubernetes    PgBouncer    Prometheus    PostgreSQL    Connection Pool
Force Tags          Kubernetes    PgBouncer    Prometheus    Health    Metrics

Library             BuiltIn
Library             String
Library             RW.Core
Library             RW.CLI
Library             RW.platform

Suite Setup         Suite Initialization


*** Tasks ***
Check PgBouncer Exporter and Process Availability for Scope `${PGBOUNCER_JOB_LABEL}`
    [Documentation]    Fails when pgbouncer_up is zero for any scraped target, indicating exporter or PgBouncer process failure.
    [Tags]    kubernetes    pgbouncer    exporter    availability    access:read-only    data:metrics

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check-exporter-up.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=PROMETHEUS_URL=${PROMETHEUS_URL} ./check-exporter-up.sh

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat check_exporter_up_output.json

    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for exporter check, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END

    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=pgbouncer_up should be 1 for every scraped PgBouncer exporter target
            ...    actual=Exporter or PgBouncer process reported unhealthy for at least one target
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END

    RW.Core.Add Pre To Report    PgBouncer exporter availability:
    RW.Core.Add Pre To Report    ${result.stdout}

Check Client Connection Saturation vs max_client_conn for Scope `${PGBOUNCER_JOB_LABEL}`
    [Documentation]    Compares active and waiting client connections to pgbouncer_config_max_client_connections and flags sustained utilization above the configured percentage threshold.
    [Tags]    kubernetes    pgbouncer    saturation    capacity    access:read-only    data:metrics

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check-client-saturation.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=PROMETHEUS_URL=${PROMETHEUS_URL} ./check-client-saturation.sh

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat check_client_saturation_output.json

    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for saturation check, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END

    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=Client active plus waiting connections should remain below the saturation threshold relative to max_client_conn
            ...    actual=Saturation ratio exceeded the configured threshold for the filtered PgBouncer targets
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END

    RW.Core.Add Pre To Report    Client saturation analysis:
    RW.Core.Add Pre To Report    ${result.stdout}

Check Client Wait Queue Buildup for Scope `${PGBOUNCER_JOB_LABEL}`
    [Documentation]    Alerts when pooled client waiting connections exceed the configured near-zero threshold, indicating pool exhaustion.
    [Tags]    kubernetes    pgbouncer    waiting    queue    access:read-only    data:metrics

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check-client-waiting.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=PROMETHEUS_URL=${PROMETHEUS_URL} ./check-client-waiting.sh

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat check_client_waiting_output.json

    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for waiting check, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END

    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=No sustained client wait queue beyond the configured threshold
            ...    actual=Client waiting connections reported above the threshold
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END

    RW.Core.Add Pre To Report    Client wait queue:
    RW.Core.Add Pre To Report    ${result.stdout}

Check Max Client Wait Time Spikes for Scope `${PGBOUNCER_JOB_LABEL}`
    [Documentation]    Evaluates pgbouncer_pools_client_maxwait_seconds against the maximum acceptable wait SLO and flags breaches.
    [Tags]    kubernetes    pgbouncer    latency    slo    access:read-only    data:metrics

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check-max-wait-time.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=PROMETHEUS_URL=${PROMETHEUS_URL} ./check-max-wait-time.sh

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat check_max_wait_time_output.json

    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for max wait check, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END

    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=pgbouncer_pools_client_maxwait_seconds should remain below the configured SLO
            ...    actual=Maximum client wait time exceeded the configured threshold
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END

    RW.Core.Add Pre To Report    Max client wait time:
    RW.Core.Add Pre To Report    ${result.stdout}

Check Server Pool Balance vs Client Waits for Scope `${PGBOUNCER_JOB_LABEL}`
    [Documentation]    Detects imbalance where clients wait while server-side idle capacity exists, or server pressure coincides with client waits.
    [Tags]    kubernetes    pgbouncer    balance    pool    access:read-only    data:metrics

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check-server-pool-balance.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=PROMETHEUS_URL=${PROMETHEUS_URL} ./check-server-pool-balance.sh

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat check_server_pool_balance_output.json

    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for pool balance check, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END

    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=Server pools should balance with client demand without persistent idle capacity while clients wait
            ...    actual=Potential imbalance or pressure pattern detected from pool metrics
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END

    RW.Core.Add Pre To Report    Server pool balance:
    RW.Core.Add Pre To Report    ${result.stdout}

Validate Pool Mode from Metrics or Config for Scope `${PGBOUNCER_JOB_LABEL}`
    [Documentation]    Confirms pool mode matches EXPECTED_POOL_MODE using metric labels when present, otherwise optional kubectl access to pgbouncer.ini in the target namespace.
    [Tags]    kubernetes    pgbouncer    pool_mode    config    access:read-only    data:metrics

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check-pool-mode.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=PROMETHEUS_URL=${PROMETHEUS_URL} ./check-pool-mode.sh

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat check_pool_mode_output.json

    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for pool mode check, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END

    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=Observed pool_mode should match EXPECTED_POOL_MODE for the workload
            ...    actual=Pool mode drift or verification gap detected
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END

    RW.Core.Add Pre To Report    Pool mode validation:
    RW.Core.Add Pre To Report    ${result.stdout}

Analyze Per-Database Connection Distribution for Scope `${PGBOUNCER_JOB_LABEL}`
    [Documentation]    Ranks databases by connection share to surface hotspots consuming a disproportionate fraction of the pool.
    [Tags]    kubernetes    pgbouncer    database    distribution    access:read-only    data:metrics

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check-per-database-distribution.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=PROMETHEUS_URL=${PROMETHEUS_URL} ./check-per-database-distribution.sh

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat check_per_database_distribution_output.json

    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for per-database check, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END

    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=Per-database connection share should remain relatively balanced for the workload
            ...    actual=One or more databases exceed the hotspot percentage threshold
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END

    RW.Core.Add Pre To Report    Per-database distribution:
    RW.Core.Add Pre To Report    ${result.stdout}

Aggregate Health Across PgBouncer Pods and Flag Outliers for Scope `${PGBOUNCER_JOB_LABEL}`
    [Documentation]    Summarizes per-pod client load and flags replicas that deviate from the fleet mean beyond the configured ratio.
    [Tags]    kubernetes    pgbouncer    outliers    pods    access:read-only    data:metrics

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check-pod-outliers.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=PROMETHEUS_URL=${PROMETHEUS_URL} ./check-pod-outliers.sh

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat check_pod_outliers_output.json

    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for pod outlier check, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END

    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=PgBouncer replicas should receive similar client load behind the Kubernetes Service
            ...    actual=One or more pods deviate from the fleet mean beyond the configured ratio
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END

    RW.Core.Add Pre To Report    Pod outlier analysis:
    RW.Core.Add Pre To Report    ${result.stdout}

Detect Abnormal Client Connection Growth Rate for Scope `${PGBOUNCER_JOB_LABEL}`
    [Documentation]    Uses a Prometheus range query over rate() to flag sustained growth in client active connections that may indicate leaks or abnormal load shifts.
    [Tags]    kubernetes    pgbouncer    growth    rate    access:read-only    data:metrics

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check-connection-growth-rate.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=PROMETHEUS_URL=${PROMETHEUS_URL} ./check-connection-growth-rate.sh

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat check_connection_growth_rate_output.json

    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for growth rate check, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END

    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=Client active connections should be stable relative to the rate threshold over the lookback window
            ...    actual=Sustained positive rate of client connection growth detected for one or more pods
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END

    RW.Core.Add Pre To Report    Connection growth rate:
    RW.Core.Add Pre To Report    ${result.stdout}

Compute Capacity Planning SLI (App Demand vs PgBouncer Capacity) for Scope `${PGBOUNCER_JOB_LABEL}`
    [Documentation]    When optional replica and pool sizes are provided, estimates demand relative to aggregate PgBouncer max_client_conn capacity and warns when approaching saturation.
    [Tags]    kubernetes    pgbouncer    capacity    planning    access:read-only    data:metrics

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check-capacity-sli.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=PROMETHEUS_URL=${PROMETHEUS_URL} ./check-capacity-sli.sh

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat check_capacity_sli_output.json

    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for capacity SLI, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END

    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=Planned application pool demand should remain below aggregate PgBouncer capacity with headroom
            ...    actual=Estimated demand ratio crossed a warning or critical threshold
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END

    RW.Core.Add Pre To Report    Capacity SLI:
    RW.Core.Add Pre To Report    ${result.stdout}


*** Keywords ***
Suite Initialization
    TRY
        ${prometheus_bearer_token}=    RW.Core.Import Secret
        ...    prometheus_bearer_token
        ...    type=string
        ...    description=Bearer token for Prometheus read API when authentication is required.
        ...    pattern=\w*
        ${prometheus_token_value}=    Set Variable    ${prometheus_bearer_token}
    EXCEPT
        Log    prometheus_bearer_token secret not present; continuing without bearer auth.    WARN
        ${prometheus_token_value}=    Set Variable    ${EMPTY}
    END

    TRY
        ${kubeconfig}=    RW.Core.Import Secret
        ...    kubeconfig
        ...    type=string
        ...    description=Kubeconfig for optional kubectl-based pool mode confirmation.
        ...    pattern=\w*
        ${kubeconfig_path}=    Set Variable    ${kubeconfig.key}
    EXCEPT
        Log    kubeconfig secret not present; kubectl-based checks may be skipped.    WARN
        ${kubeconfig_path}=    Set Variable    ${EMPTY}
    END

    ${PROMETHEUS_URL}=    RW.Core.Import User Variable    PROMETHEUS_URL
    ...    type=string
    ...    description=Base URL for Prometheus or Thanos querier API (e.g. https://prometheus.example/api/v1/).
    ...    pattern=https?://.*
    ${PGBOUNCER_JOB_LABEL}=    RW.Core.Import User Variable    PGBOUNCER_JOB_LABEL
    ...    type=string
    ...    description=Prometheus label matcher for the PgBouncer exporter job, e.g. job="pgbouncer-exporter".
    ...    pattern=.*
    ${EXPECTED_POOL_MODE}=    RW.Core.Import User Variable    EXPECTED_POOL_MODE
    ...    type=string
    ...    description=Expected pool mode (transaction, session, or statement).
    ...    pattern=\w*
    ${CONTEXT}=    RW.Core.Import User Variable    CONTEXT
    ...    type=string
    ...    description=Kubernetes context name for kubectl commands when kubeconfig is provided.
    ...    default=
    ...    pattern=.*
    ${METRIC_NAMESPACE_FILTER}=    RW.Core.Import User Variable    METRIC_NAMESPACE_FILTER
    ...    type=string
    ...    description=Additional Prometheus label matcher for namespace or kubernetes_namespace.
    ...    default=
    ...    pattern=.*
    ${CLIENT_SATURATION_PERCENT_THRESHOLD}=    RW.Core.Import User Variable    CLIENT_SATURATION_PERCENT_THRESHOLD
    ...    type=string
    ...    description=Alert when active plus waiting connections exceed this percent of max_client_conn.
    ...    default=80
    ...    pattern=\w*
    ${MAX_WAIT_SECONDS_THRESHOLD}=    RW.Core.Import User Variable    MAX_WAIT_SECONDS_THRESHOLD
    ...    type=string
    ...    description=Maximum acceptable pgbouncer_pools_client_maxwait_seconds.
    ...    default=1
    ...    pattern=\w*
    ${CLIENT_WAITING_THRESHOLD}=    RW.Core.Import User Variable    CLIENT_WAITING_THRESHOLD
    ...    type=string
    ...    description=Alert when sum of waiting connections is greater than this value.
    ...    default=0
    ...    pattern=\w*
    ${DATABASE_HOTSPOT_PERCENT_THRESHOLD}=    RW.Core.Import User Variable    DATABASE_HOTSPOT_PERCENT_THRESHOLD
    ...    type=string
    ...    description=Flag databases whose share of connections exceeds this percent of the total.
    ...    default=50
    ...    pattern=\w*
    ${POD_OUTLIER_RATIO}=    RW.Core.Import User Variable    POD_OUTLIER_RATIO
    ...    type=string
    ...    description=Flag pods whose per-pod client active sum exceeds the fleet mean times this ratio.
    ...    default=2.0
    ...    pattern=[0-9.]+
    ${GROWTH_RATE_WINDOW_MINUTES}=    RW.Core.Import User Variable    GROWTH_RATE_WINDOW_MINUTES
    ...    type=string
    ...    description=Lookback window in minutes for Prometheus range queries on connection growth.
    ...    default=15
    ...    pattern=\w*
    ${CONNECTION_GROWTH_RATE_THRESHOLD}=    RW.Core.Import User Variable    CONNECTION_GROWTH_RATE_THRESHOLD
    ...    type=string
    ...    description=Average rate of client connections (per second) above which a growth issue is raised.
    ...    default=0.1
    ...    pattern=[0-9.]+
    ${KUBERNETES_DISTRIBUTION_BINARY}=    RW.Core.Import User Variable    KUBERNETES_DISTRIBUTION_BINARY
    ...    type=string
    ...    description=Kubernetes CLI binary to use for optional kubectl checks.
    ...    default=kubectl
    ...    pattern=\w*
    ${PGBOUNCER_NAMESPACE}=    RW.Core.Import User Variable    PGBOUNCER_NAMESPACE
    ...    type=string
    ...    description=Namespace containing a PgBouncer pod for optional pool_mode.ini inspection via kubectl.
    ...    default=
    ...    pattern=.*
    ${PGBOUNCER_POD_LABEL_SELECTOR}=    RW.Core.Import User Variable    PGBOUNCER_POD_LABEL_SELECTOR
    ...    type=string
    ...    description=Label selector used to locate a PgBouncer pod for optional pool mode verification.
    ...    default=app.kubernetes.io/name=pgbouncer-exporter
    ...    pattern=.*
    ${PGBOUNCER_PGBOUNCER_CONTAINER}=    RW.Core.Import User Variable    PGBOUNCER_PGBOUNCER_CONTAINER
    ...    type=string
    ...    description=Optional container name for kubectl exec when the pod has multiple containers.
    ...    default=
    ...    pattern=.*
    ${APP_REPLICAS}=    RW.Core.Import User Variable    APP_REPLICAS
    ...    type=string
    ...    description=Application replica count for capacity SLI (optional).
    ...    default=
    ...    pattern=.*
    ${APP_DB_POOL_SIZE}=    RW.Core.Import User Variable    APP_DB_POOL_SIZE
    ...    type=string
    ...    description=Per-app SQL pool size for capacity SLI (optional).
    ...    default=
    ...    pattern=.*
    ${PGBOUNCER_REPLICAS}=    RW.Core.Import User Variable    PGBOUNCER_REPLICAS
    ...    type=string
    ...    description=PgBouncer deployment replica count for capacity SLI (optional).
    ...    default=
    ...    pattern=.*

    Set Suite Variable    ${PROMETHEUS_URL}    ${PROMETHEUS_URL}
    Set Suite Variable    ${PGBOUNCER_JOB_LABEL}    ${PGBOUNCER_JOB_LABEL}
    Set Suite Variable    ${EXPECTED_POOL_MODE}    ${EXPECTED_POOL_MODE}
    Set Suite Variable    ${CONTEXT}    ${CONTEXT}
    Set Suite Variable    ${METRIC_NAMESPACE_FILTER}    ${METRIC_NAMESPACE_FILTER}
    Set Suite Variable    ${CLIENT_SATURATION_PERCENT_THRESHOLD}    ${CLIENT_SATURATION_PERCENT_THRESHOLD}
    Set Suite Variable    ${MAX_WAIT_SECONDS_THRESHOLD}    ${MAX_WAIT_SECONDS_THRESHOLD}
    Set Suite Variable    ${CLIENT_WAITING_THRESHOLD}    ${CLIENT_WAITING_THRESHOLD}
    Set Suite Variable    ${DATABASE_HOTSPOT_PERCENT_THRESHOLD}    ${DATABASE_HOTSPOT_PERCENT_THRESHOLD}
    Set Suite Variable    ${POD_OUTLIER_RATIO}    ${POD_OUTLIER_RATIO}
    Set Suite Variable    ${GROWTH_RATE_WINDOW_MINUTES}    ${GROWTH_RATE_WINDOW_MINUTES}
    Set Suite Variable    ${CONNECTION_GROWTH_RATE_THRESHOLD}    ${CONNECTION_GROWTH_RATE_THRESHOLD}
    Set Suite Variable    ${KUBERNETES_DISTRIBUTION_BINARY}    ${KUBERNETES_DISTRIBUTION_BINARY}
    Set Suite Variable    ${PGBOUNCER_NAMESPACE}    ${PGBOUNCER_NAMESPACE}
    Set Suite Variable    ${PGBOUNCER_POD_LABEL_SELECTOR}    ${PGBOUNCER_POD_LABEL_SELECTOR}
    Set Suite Variable    ${PGBOUNCER_PGBOUNCER_CONTAINER}    ${PGBOUNCER_PGBOUNCER_CONTAINER}
    Set Suite Variable    ${APP_REPLICAS}    ${APP_REPLICAS}
    Set Suite Variable    ${APP_DB_POOL_SIZE}    ${APP_DB_POOL_SIZE}
    Set Suite Variable    ${PGBOUNCER_REPLICAS}    ${PGBOUNCER_REPLICAS}

    ${env}=    Create Dictionary
    ...    PROMETHEUS_URL=${PROMETHEUS_URL}
    ...    PGBOUNCER_JOB_LABEL=${PGBOUNCER_JOB_LABEL}
    ...    EXPECTED_POOL_MODE=${EXPECTED_POOL_MODE}
    ...    CONTEXT=${CONTEXT}
    ...    METRIC_NAMESPACE_FILTER=${METRIC_NAMESPACE_FILTER}
    ...    CLIENT_SATURATION_PERCENT_THRESHOLD=${CLIENT_SATURATION_PERCENT_THRESHOLD}
    ...    MAX_WAIT_SECONDS_THRESHOLD=${MAX_WAIT_SECONDS_THRESHOLD}
    ...    CLIENT_WAITING_THRESHOLD=${CLIENT_WAITING_THRESHOLD}
    ...    DATABASE_HOTSPOT_PERCENT_THRESHOLD=${DATABASE_HOTSPOT_PERCENT_THRESHOLD}
    ...    POD_OUTLIER_RATIO=${POD_OUTLIER_RATIO}
    ...    GROWTH_RATE_WINDOW_MINUTES=${GROWTH_RATE_WINDOW_MINUTES}
    ...    CONNECTION_GROWTH_RATE_THRESHOLD=${CONNECTION_GROWTH_RATE_THRESHOLD}
    ...    KUBERNETES_DISTRIBUTION_BINARY=${KUBERNETES_DISTRIBUTION_BINARY}
    ...    PGBOUNCER_NAMESPACE=${PGBOUNCER_NAMESPACE}
    ...    PGBOUNCER_POD_LABEL_SELECTOR=${PGBOUNCER_POD_LABEL_SELECTOR}
    ...    PGBOUNCER_PGBOUNCER_CONTAINER=${PGBOUNCER_PGBOUNCER_CONTAINER}
    ...    APP_REPLICAS=${APP_REPLICAS}
    ...    APP_DB_POOL_SIZE=${APP_DB_POOL_SIZE}
    ...    PGBOUNCER_REPLICAS=${PGBOUNCER_REPLICAS}
    ...    PROMETHEUS_BEARER_TOKEN=${prometheus_token_value}
    ...    KUBECONFIG=${kubeconfig_path}
    Set Suite Variable    ${env}    ${env}
