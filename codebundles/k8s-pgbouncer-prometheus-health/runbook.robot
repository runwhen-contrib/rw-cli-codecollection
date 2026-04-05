*** Settings ***
Documentation       Evaluates PgBouncer connection pool health using Prometheus metrics from prometheus-community/pgbouncer_exporter with cluster aggregation and per-pod diagnostics.
Metadata            Author    rw-codebundle-agent
Metadata            Display Name    Kubernetes PgBouncer Prometheus Health
Metadata            Supports    Kubernetes    PgBouncer    Prometheus    Metrics    ConnectionPool

Force Tags          Kubernetes    PgBouncer    Prometheus    Health    Metrics

Library             String
Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform

Suite Setup         Suite Initialization


*** Tasks ***
Check PgBouncer Exporter and Process Availability for Scope `${PGBOUNCER_JOB_LABEL}`
    [Documentation]    Fails when pgbouncer_up is zero for any matching series or when no series match, indicating exporter or PgBouncer process failure.
    [Tags]    kubernetes    pgbouncer    prometheus    exporter    availability    access:read-only    data:metrics

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check-exporter-up.sh
    ...    env=${env}
    ...    secret__prometheus_bearer_token=${prometheus_bearer_token}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=PROMETHEUS_URL="${PROMETHEUS_URL}" ./check-exporter-up.sh

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat check_exporter_up.json

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
            ...    expected=pgbouncer_up should be 1 for healthy exporter and PgBouncer process for scope `${PGBOUNCER_JOB_LABEL}`
            ...    actual=Exporter or process health issue detected for `${PGBOUNCER_JOB_LABEL}`
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END

    RW.Core.Add Pre To Report    PgBouncer exporter availability (`${PGBOUNCER_JOB_LABEL}`):
    RW.Core.Add Pre To Report    ${result.stdout}

Check Client Connection Saturation vs max_client_conn for Scope `${PGBOUNCER_JOB_LABEL}`
    [Documentation]    Compares summed client active (and optionally waiting) connections to pgbouncer_config_max_client_connections against the saturation percent threshold.
    [Tags]    kubernetes    pgbouncer    prometheus    saturation    capacity    access:read-only    data:metrics

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check-client-saturation.sh
    ...    env=${env}
    ...    secret__prometheus_bearer_token=${prometheus_bearer_token}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=false
    ...    cmd_override=PROMETHEUS_URL="${PROMETHEUS_URL}" ./check-client-saturation.sh

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat check_client_saturation.json

    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for client saturation, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END

    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=Client active load should remain below ${CLIENT_SATURATION_PERCENT_THRESHOLD}% of max_client_conn for `${PGBOUNCER_JOB_LABEL}`
            ...    actual=High client saturation detected for `${PGBOUNCER_JOB_LABEL}`
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END

    RW.Core.Add Pre To Report    Client saturation (`${PGBOUNCER_JOB_LABEL}`):
    RW.Core.Add Pre To Report    ${result.stdout}

Check Client Wait Queue Buildup for Scope `${PGBOUNCER_JOB_LABEL}`
    [Documentation]    Alerts when summed client waiting connections exceed the configured near-zero threshold, indicating pool exhaustion.
    [Tags]    kubernetes    pgbouncer    prometheus    waiting    queue    access:read-only    data:metrics

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check-client-waiting.sh
    ...    env=${env}
    ...    secret__prometheus_bearer_token=${prometheus_bearer_token}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=false
    ...    cmd_override=PROMETHEUS_URL="${PROMETHEUS_URL}" ./check-client-waiting.sh

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat check_client_waiting.json

    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for client waiting, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END

    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=Client waiting connections should stay at or below ${CLIENT_WAITING_MIN_THRESHOLD} for `${PGBOUNCER_JOB_LABEL}`
            ...    actual=Client wait queue buildup detected for `${PGBOUNCER_JOB_LABEL}`
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END

    RW.Core.Add Pre To Report    Client waiting connections (`${PGBOUNCER_JOB_LABEL}`):
    RW.Core.Add Pre To Report    ${result.stdout}

Check Max Client Wait Time Spikes for Scope `${PGBOUNCER_JOB_LABEL}`
    [Documentation]    Evaluates maximum pgbouncer_pools_client_maxwait_seconds against the max wait seconds threshold for SLO breaches.
    [Tags]    kubernetes    pgbouncer    prometheus    latency    slo    access:read-only    data:metrics

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check-max-wait-time.sh
    ...    env=${env}
    ...    secret__prometheus_bearer_token=${prometheus_bearer_token}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=false
    ...    cmd_override=PROMETHEUS_URL="${PROMETHEUS_URL}" ./check-max-wait-time.sh

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat check_max_wait_time.json

    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for max wait time, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END

    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=Max client wait should remain below ${MAX_WAIT_SECONDS_THRESHOLD}s for `${PGBOUNCER_JOB_LABEL}`
            ...    actual=Elevated max wait time detected for `${PGBOUNCER_JOB_LABEL}`
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END

    RW.Core.Add Pre To Report    Max client wait time (`${PGBOUNCER_JOB_LABEL}`):
    RW.Core.Add Pre To Report    ${result.stdout}

Check Server Pool Balance vs Client Waits for Scope `${PGBOUNCER_JOB_LABEL}`
    [Documentation]    Detects imbalance where clients wait while server-side idle capacity exists, and flags databases near max connections with concurrent waits.
    [Tags]    kubernetes    pgbouncer    prometheus    balance    pools    access:read-only    data:metrics

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check-server-pool-balance.sh
    ...    env=${env}
    ...    secret__prometheus_bearer_token=${prometheus_bearer_token}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=false
    ...    cmd_override=PROMETHEUS_URL="${PROMETHEUS_URL}" ./check-server-pool-balance.sh

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat check_server_pool_balance.json

    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for server pool balance, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END

    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=Server pools should not show idle headroom while clients wait, and databases should not sit near max_connections with waits for `${PGBOUNCER_JOB_LABEL}`
            ...    actual=Pool balance anomaly detected for `${PGBOUNCER_JOB_LABEL}`
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END

    RW.Core.Add Pre To Report    Server pool balance (`${PGBOUNCER_JOB_LABEL}`):
    RW.Core.Add Pre To Report    ${result.stdout}

Validate Pool Mode from Metrics for Scope `${PGBOUNCER_JOB_LABEL}`
    [Documentation]    Confirms pool_mode from pgbouncer_databases_current_connections labels matches EXPECTED_POOL_MODE.
    [Tags]    kubernetes    pgbouncer    prometheus    pool_mode    config    access:read-only    data:metrics

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check-pool-mode.sh
    ...    env=${env}
    ...    secret__prometheus_bearer_token=${prometheus_bearer_token}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=false
    ...    cmd_override=PROMETHEUS_URL="${PROMETHEUS_URL}" ./check-pool-mode.sh

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat check_pool_mode.json

    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for pool mode, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END

    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=Observed pool_mode should match ${EXPECTED_POOL_MODE} for `${PGBOUNCER_JOB_LABEL}`
            ...    actual=Pool mode validation failed for `${PGBOUNCER_JOB_LABEL}`
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END

    RW.Core.Add Pre To Report    Pool mode validation (`${PGBOUNCER_JOB_LABEL}`):
    RW.Core.Add Pre To Report    ${result.stdout}

Analyze Per-Database Connection Distribution for Scope `${PGBOUNCER_JOB_LABEL}`
    [Documentation]    Ranks databases by current_connections and flags dominance hotspots above the configured share ratio.
    [Tags]    kubernetes    pgbouncer    prometheus    database    distribution    access:read-only    data:metrics

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check-per-database-distribution.sh
    ...    env=${env}
    ...    secret__prometheus_bearer_token=${prometheus_bearer_token}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=false
    ...    cmd_override=PROMETHEUS_URL="${PROMETHEUS_URL}" ./check-per-database-distribution.sh

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat check_per_database_distribution.json

    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for per-database distribution, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END

    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=No single database should consume a dominant share of connections for `${PGBOUNCER_JOB_LABEL}`
            ...    actual=Hotspot database detected for `${PGBOUNCER_JOB_LABEL}`
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END

    RW.Core.Add Pre To Report    Per-database distribution (`${PGBOUNCER_JOB_LABEL}`):
    RW.Core.Add Pre To Report    ${result.stdout}

Aggregate Health Across PgBouncer Pods and Flag Outliers for Scope `${PGBOUNCER_JOB_LABEL}`
    [Documentation]    Compares per-pod client active connections to the fleet median and flags high outliers.
    [Tags]    kubernetes    pgbouncer    prometheus    pods    outliers    access:read-only    data:metrics

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check-pod-outliers.sh
    ...    env=${env}
    ...    secret__prometheus_bearer_token=${prometheus_bearer_token}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=false
    ...    cmd_override=PROMETHEUS_URL="${PROMETHEUS_URL}" ./check-pod-outliers.sh

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat check_pod_outliers.json

    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for pod outliers, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END

    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=PgBouncer pods should see similar client active load for `${PGBOUNCER_JOB_LABEL}`
            ...    actual=Outlier pod load detected for `${PGBOUNCER_JOB_LABEL}`
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END

    RW.Core.Add Pre To Report    Pod outliers (`${PGBOUNCER_JOB_LABEL}`):
    RW.Core.Add Pre To Report    ${result.stdout}

Detect Abnormal Client Connection Growth Rate for Scope `${PGBOUNCER_JOB_LABEL}`
    [Documentation]    Uses sum(delta(...)) over the lookback window on client active connections to flag rapid growth suggestive of leaks or shifting load.
    [Tags]    kubernetes    pgbouncer    prometheus    growth    leaks    access:read-only    data:metrics

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check-connection-growth-rate.sh
    ...    env=${env}
    ...    secret__prometheus_bearer_token=${prometheus_bearer_token}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=false
    ...    cmd_override=PROMETHEUS_URL="${PROMETHEUS_URL}" ./check-connection-growth-rate.sh

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat check_connection_growth_rate.json

    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for connection growth, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END

    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=Client active connections should grow gradually relative to load for `${PGBOUNCER_JOB_LABEL}`
            ...    actual=Abnormal connection growth detected for `${PGBOUNCER_JOB_LABEL}`
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END

    RW.Core.Add Pre To Report    Connection growth rate (`${PGBOUNCER_JOB_LABEL}`):
    RW.Core.Add Pre To Report    ${result.stdout}

Compute Capacity Planning SLI for Scope `${PGBOUNCER_JOB_LABEL}`
    [Documentation]    When APP_REPLICAS, APP_DB_POOL_SIZE, and PGBOUNCER_REPLICAS are provided, compares estimated app demand to nominal PgBouncer capacity using max_client_conn from metrics.
    [Tags]    kubernetes    pgbouncer    prometheus    capacity    sli    access:read-only    data:metrics

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check-capacity-sli.sh
    ...    env=${env}
    ...    secret__prometheus_bearer_token=${prometheus_bearer_token}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=false
    ...    cmd_override=PROMETHEUS_URL="${PROMETHEUS_URL}" ./check-capacity-sli.sh

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat check_capacity_sli.json

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
            ...    expected=Estimated demand ratio should stay below 1.0 with headroom for `${PGBOUNCER_JOB_LABEL}`
            ...    actual=Capacity SLI indicates risk for `${PGBOUNCER_JOB_LABEL}`
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END

    RW.Core.Add Pre To Report    Capacity SLI (`${PGBOUNCER_JOB_LABEL}`):
    RW.Core.Add Pre To Report    ${result.stdout}


*** Keywords ***
Suite Initialization
    TRY
        ${prometheus_bearer_token}=    RW.Core.Import Secret
        ...    prometheus_bearer_token
        ...    type=string
        ...    description=Bearer token for Prometheus HTTP API when authentication is required.
        ...    pattern=\w*
    EXCEPT
        Log    prometheus_bearer_token not provided; queries will use unauthenticated access.    WARN
        ${prometheus_bearer_token}=    Set Variable    ${EMPTY}
    END

    TRY
        ${kubeconfig}=    RW.Core.Import Secret
        ...    kubeconfig
        ...    type=string
        ...    description=Kubeconfig for optional kubectl-based validation outside this bundle.
        ...    pattern=\w*
    EXCEPT
        Log    kubeconfig not provided; only Prometheus queries will run.    WARN
        ${kubeconfig}=    Set Variable    ${EMPTY}
    END

    ${CONTEXT}=    RW.Core.Import User Variable    CONTEXT
    ...    type=string
    ...    description=Kubernetes context name for paired kubectl workflows.
    ...    default=
    ...    pattern=\w*

    ${PROMETHEUS_URL}=    RW.Core.Import User Variable    PROMETHEUS_URL
    ...    type=string
    ...    description=Base URL for Prometheus or Thanos querier (for example https://prom.example.com or including /api/v1/).
    ...    pattern=\w*

    ${METRIC_NAMESPACE_FILTER}=    RW.Core.Import User Variable    METRIC_NAMESPACE_FILTER
    ...    type=string
    ...    description=Value matched against METRIC_NAMESPACE_LABEL to scope metrics.
    ...    default=
    ...    pattern=\w*

    ${METRIC_NAMESPACE_LABEL}=    RW.Core.Import User Variable    METRIC_NAMESPACE_LABEL
    ...    type=string
    ...    description=Prometheus label name for namespace scoping (kubernetes_namespace or namespace).
    ...    default=kubernetes_namespace
    ...    pattern=\w*

    ${PGBOUNCER_JOB_LABEL}=    RW.Core.Import User Variable    PGBOUNCER_JOB_LABEL
    ...    type=string
    ...    description=Label selector fragment for the exporter job (for example job=\"pgbouncer-exporter\").
    ...    pattern=\w*

    ${CLIENT_SATURATION_PERCENT_THRESHOLD}=    RW.Core.Import User Variable    CLIENT_SATURATION_PERCENT_THRESHOLD
    ...    type=string
    ...    description=Percent of max_client_conn before saturation is raised.
    ...    default=80
    ...    pattern=\w*

    ${INCLUDE_WAITING_IN_SATURATION}=    RW.Core.Import User Variable    INCLUDE_WAITING_IN_SATURATION
    ...    type=string
    ...    description=When true, include client waiting connections in saturation numerator.
    ...    default=true
    ...    pattern=\w*

    ${CLIENT_WAITING_MIN_THRESHOLD}=    RW.Core.Import User Variable    CLIENT_WAITING_MIN_THRESHOLD
    ...    type=string
    ...    description=Minimum sum of waiting connections that triggers an issue.
    ...    default=0
    ...    pattern=\w*

    ${MAX_WAIT_SECONDS_THRESHOLD}=    RW.Core.Import User Variable    MAX_WAIT_SECONDS_THRESHOLD
    ...    type=string
    ...    description=Maximum acceptable pgbouncer_pools_client_maxwait_seconds.
    ...    default=1
    ...    pattern=\w*

    ${EXPECTED_POOL_MODE}=    RW.Core.Import User Variable    EXPECTED_POOL_MODE
    ...    type=string
    ...    description=Expected pool mode (transaction, session, or statement).
    ...    pattern=\w*

    ${APP_REPLICAS}=    RW.Core.Import User Variable    APP_REPLICAS
    ...    type=string
    ...    description=Application replica count for optional capacity SLI.
    ...    default=
    ...    pattern=\w*

    ${APP_DB_POOL_SIZE}=    RW.Core.Import User Variable    APP_DB_POOL_SIZE
    ...    type=string
    ...    description=Per-replica DB pool size for optional capacity SLI.
    ...    default=
    ...    pattern=\w*

    ${PGBOUNCER_REPLICAS}=    RW.Core.Import User Variable    PGBOUNCER_REPLICAS
    ...    type=string
    ...    description=PgBouncer replica count for optional capacity SLI.
    ...    default=
    ...    pattern=\w*

    ${CONNECTION_GROWTH_LOOKBACK}=    RW.Core.Import User Variable    CONNECTION_GROWTH_LOOKBACK
    ...    type=string
    ...    description=Prometheus range duration for delta() growth checks (for example 15m).
    ...    default=15m
    ...    pattern=\w*

    ${CONNECTION_GROWTH_DELTA_THRESHOLD}=    RW.Core.Import User Variable    CONNECTION_GROWTH_DELTA_THRESHOLD
    ...    type=string
    ...    description=Total connection increase over the lookback window that triggers growth issues.
    ...    default=8
    ...    pattern=\w*

    ${POD_OUTLIER_RATIO}=    RW.Core.Import User Variable    POD_OUTLIER_RATIO
    ...    type=string
    ...    description=Multiplier over fleet median client active load to flag a pod outlier.
    ...    default=1.4
    ...    pattern=\w*

    ${METRIC_POD_LABEL}=    RW.Core.Import User Variable    METRIC_POD_LABEL
    ...    type=string
    ...    description=Label name identifying the pod in Prometheus series (pod or kubernetes_pod_name).
    ...    default=pod
    ...    pattern=\w*

    ${DATABASE_DOMINANCE_RATIO}=    RW.Core.Import User Variable    DATABASE_DOMINANCE_RATIO
    ...    type=string
    ...    description=Fraction of total connections above which a single database is flagged as a hotspot.
    ...    default=0.45
    ...    pattern=\w*

    Set Suite Variable    ${CONTEXT}    ${CONTEXT}
    Set Suite Variable    ${PROMETHEUS_URL}    ${PROMETHEUS_URL}
    Set Suite Variable    ${METRIC_NAMESPACE_FILTER}    ${METRIC_NAMESPACE_FILTER}
    Set Suite Variable    ${METRIC_NAMESPACE_LABEL}    ${METRIC_NAMESPACE_LABEL}
    Set Suite Variable    ${PGBOUNCER_JOB_LABEL}    ${PGBOUNCER_JOB_LABEL}
    Set Suite Variable    ${CLIENT_SATURATION_PERCENT_THRESHOLD}    ${CLIENT_SATURATION_PERCENT_THRESHOLD}
    Set Suite Variable    ${INCLUDE_WAITING_IN_SATURATION}    ${INCLUDE_WAITING_IN_SATURATION}
    Set Suite Variable    ${CLIENT_WAITING_MIN_THRESHOLD}    ${CLIENT_WAITING_MIN_THRESHOLD}
    Set Suite Variable    ${MAX_WAIT_SECONDS_THRESHOLD}    ${MAX_WAIT_SECONDS_THRESHOLD}
    Set Suite Variable    ${EXPECTED_POOL_MODE}    ${EXPECTED_POOL_MODE}
    Set Suite Variable    ${APP_REPLICAS}    ${APP_REPLICAS}
    Set Suite Variable    ${APP_DB_POOL_SIZE}    ${APP_DB_POOL_SIZE}
    Set Suite Variable    ${PGBOUNCER_REPLICAS}    ${PGBOUNCER_REPLICAS}
    Set Suite Variable    ${CONNECTION_GROWTH_LOOKBACK}    ${CONNECTION_GROWTH_LOOKBACK}
    Set Suite Variable    ${CONNECTION_GROWTH_DELTA_THRESHOLD}    ${CONNECTION_GROWTH_DELTA_THRESHOLD}
    Set Suite Variable    ${POD_OUTLIER_RATIO}    ${POD_OUTLIER_RATIO}
    Set Suite Variable    ${METRIC_POD_LABEL}    ${METRIC_POD_LABEL}
    Set Suite Variable    ${DATABASE_DOMINANCE_RATIO}    ${DATABASE_DOMINANCE_RATIO}

    ${env}=    Create Dictionary
    ...    CONTEXT=${CONTEXT}
    ...    PROMETHEUS_URL=${PROMETHEUS_URL}
    ...    METRIC_NAMESPACE_FILTER=${METRIC_NAMESPACE_FILTER}
    ...    METRIC_NAMESPACE_LABEL=${METRIC_NAMESPACE_LABEL}
    ...    PGBOUNCER_JOB_LABEL=${PGBOUNCER_JOB_LABEL}
    ...    CLIENT_SATURATION_PERCENT_THRESHOLD=${CLIENT_SATURATION_PERCENT_THRESHOLD}
    ...    INCLUDE_WAITING_IN_SATURATION=${INCLUDE_WAITING_IN_SATURATION}
    ...    CLIENT_WAITING_MIN_THRESHOLD=${CLIENT_WAITING_MIN_THRESHOLD}
    ...    MAX_WAIT_SECONDS_THRESHOLD=${MAX_WAIT_SECONDS_THRESHOLD}
    ...    EXPECTED_POOL_MODE=${EXPECTED_POOL_MODE}
    ...    APP_REPLICAS=${APP_REPLICAS}
    ...    APP_DB_POOL_SIZE=${APP_DB_POOL_SIZE}
    ...    PGBOUNCER_REPLICAS=${PGBOUNCER_REPLICAS}
    ...    CONNECTION_GROWTH_LOOKBACK=${CONNECTION_GROWTH_LOOKBACK}
    ...    CONNECTION_GROWTH_DELTA_THRESHOLD=${CONNECTION_GROWTH_DELTA_THRESHOLD}
    ...    POD_OUTLIER_RATIO=${POD_OUTLIER_RATIO}
    ...    METRIC_POD_LABEL=${METRIC_POD_LABEL}
    ...    DATABASE_DOMINANCE_RATIO=${DATABASE_DOMINANCE_RATIO}
    Set Suite Variable    ${env}    ${env}
