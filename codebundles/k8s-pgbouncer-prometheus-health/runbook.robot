*** Settings ***
Documentation       Evaluates PgBouncer connection pool health using Prometheus metrics from prometheus-community/pgbouncer_exporter with cluster-wide aggregation and per-pod diagnostics.
Metadata            Author    rw-codebundle-agent
Metadata            Display Name    Kubernetes PgBouncer Prometheus Health
Metadata            Supports    Kubernetes    PgBouncer    Prometheus    Metrics    Health
Force Tags          Kubernetes    PgBouncer    Prometheus    Health    Metrics

Library             BuiltIn
Library             String
Library             RW.Core
Library             RW.CLI
Library             RW.platform

Suite Setup         Suite Initialization


*** Tasks ***
Check PgBouncer Exporter and Process Availability for Scope `${PGBOUNCER_JOB_LABEL}`
    [Documentation]    Fails when pgbouncer_up is zero for any scraped pod or instance, indicating exporter or PgBouncer process failure.
    [Tags]    kubernetes    pgbouncer    prometheus    exporter    access:read-only    data:metrics

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check-exporter-up.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=curl -sS -X POST "${PROMETHEUS_URL%/}/api/v1/query" --data-urlencode 'query=pgbouncer_up{...}'

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat exporter_up_analysis.json

    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END

    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=pgbouncer_up should be 1 for all scraped PgBouncer exporter targets
            ...    actual=Exporter or PgBouncer reported down for at least one target
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END

    RW.Core.Add Pre To Report    PgBouncer exporter availability:
    RW.Core.Add Pre To Report    ${result.stdout}

Check Client Connection Saturation vs max_client_conn for `${PGBOUNCER_JOB_LABEL}`
    [Documentation]    Compares summed client active and waiting connections to pgbouncer_config_max_client_connections per pod and flags utilization above CLIENT_SATURATION_PERCENT_THRESHOLD.
    [Tags]    kubernetes    pgbouncer    saturation    access:read-only    data:metrics

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check-client-saturation.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=PROMETHEUS_URL=${PROMETHEUS_URL} ./check-client-saturation.sh

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat client_saturation_analysis.json

    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END

    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=Client utilization should remain below the configured saturation threshold
            ...    actual=High client saturation detected against max_client_conn
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END

    RW.Core.Add Pre To Report    Client saturation analysis:
    RW.Core.Add Pre To Report    ${result.stdout}

Check Client Wait Queue Buildup for `${PGBOUNCER_JOB_LABEL}`
    [Documentation]    Alerts when summed pgbouncer_pools_client_waiting_connections exceeds CLIENT_WAITING_THRESHOLD indicating pool exhaustion.
    [Tags]    kubernetes    pgbouncer    waiting    access:read-only    data:metrics

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check-client-waiting.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./check-client-waiting.sh

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat client_waiting_analysis.json

    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END

    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=Client waiting connections should stay at or near zero
            ...    actual=Clients are waiting for server connections
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END

    RW.Core.Add Pre To Report    Client wait queue:
    RW.Core.Add Pre To Report    ${result.stdout}

Check Max Client Wait Time Spikes for `${PGBOUNCER_JOB_LABEL}`
    [Documentation]    Evaluates pgbouncer_pools_client_maxwait_seconds against MAX_WAIT_SECONDS_THRESHOLD to catch SLO breaches by pod, database, and user labels.
    [Tags]    kubernetes    pgbouncer    latency    access:read-only    data:metrics

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check-max-wait-time.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./check-max-wait-time.sh

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat max_wait_time_analysis.json

    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END

    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=Max client wait time should remain below the configured threshold
            ...    actual=Elevated maxwait observed for one or more pools
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END

    RW.Core.Add Pre To Report    Max wait time results:
    RW.Core.Add Pre To Report    ${result.stdout}

Check Server Pool Balance vs Client Waits for `${PGBOUNCER_JOB_LABEL}`
    [Documentation]    Detects pools where clients wait while server_idle connections remain, suggesting misconfiguration or routing issues.
    [Tags]    kubernetes    pgbouncer    balance    access:read-only    data:metrics

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check-server-pool-balance.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./check-server-pool-balance.sh

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat server_pool_balance_analysis.json

    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END

    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=Waiting clients should not coexist with idle server capacity in the same pool without cause
            ...    actual=Imbalance between client waits and idle servers detected
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END

    RW.Core.Add Pre To Report    Server pool balance:
    RW.Core.Add Pre To Report    ${result.stdout}

Validate Pool Mode from Metrics for `${EXPECTED_POOL_MODE}`
    [Documentation]    Confirms pool_mode labels on pgbouncer_databases_current_connections match EXPECTED_POOL_MODE for transaction, session, or statement mode.
    [Tags]    kubernetes    pgbouncer    pool-mode    access:read-only    data:metrics

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check-pool-mode.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./check-pool-mode.sh

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat pool_mode_analysis.json

    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END

    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=Observed pool_mode should match EXPECTED_POOL_MODE
            ...    actual=Pool mode drift or missing pool_mode label detected
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END

    RW.Core.Add Pre To Report    Pool mode validation:
    RW.Core.Add Pre To Report    ${result.stdout}

Analyze Per-Database Connection Distribution for `${PGBOUNCER_JOB_LABEL}`
    [Documentation]    Ranks databases by pgbouncer_databases_current_connections share to surface hotspots above DATABASE_HOTSPOT_PERCENT_THRESHOLD.
    [Tags]    kubernetes    pgbouncer    databases    access:read-only    data:metrics

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check-per-database-distribution.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./check-per-database-distribution.sh

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat per_database_distribution_analysis.json

    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END

    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=Database share of connections should be relatively balanced for the workload profile
            ...    actual=One or more databases consume a disproportionate share of connections
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END

    RW.Core.Add Pre To Report    Per-database distribution:
    RW.Core.Add Pre To Report    ${result.stdout}

Aggregate Health Across PgBouncer Pods and Flag Outliers for `${PGBOUNCER_JOB_LABEL}`
    [Documentation]    Summarizes client_active per pod and flags pods that deviate from the fleet median by POD_OUTLIER_DEVIATION_PERCENT.
    [Tags]    kubernetes    pgbouncer    outliers    access:read-only    data:metrics

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check-pod-outliers.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./check-pod-outliers.sh

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat pod_outliers_analysis.json

    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END

    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=Pods behind the service should carry similar client load at steady state
            ...    actual=One or more pods deviate strongly from the median
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END

    RW.Core.Add Pre To Report    Pod outlier analysis:
    RW.Core.Add Pre To Report    ${result.stdout}

Detect Abnormal Client Connection Growth Rate for `${PGBOUNCER_JOB_LABEL}`
    [Documentation]    Uses a Prometheus range query to compare first and last sum of client active connections over CONNECTION_GROWTH_LOOKBACK_MINUTES to flag sustained growth.
    [Tags]    kubernetes    pgbouncer    growth    access:read-only    data:metrics

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check-connection-growth-rate.sh
    ...    env=${env}
    ...    timeout_seconds=240
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./check-connection-growth-rate.sh

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat connection_growth_analysis.json

    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END

    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=Aggregate client connections should be stable relative to traffic when pools are healthy
            ...    actual=Sustained growth in client active connections observed over the lookback window
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END

    RW.Core.Add Pre To Report    Connection growth analysis:
    RW.Core.Add Pre To Report    ${result.stdout}

Compute Capacity Planning SLI App Demand vs PgBouncer Capacity
    [Documentation]    When APP_REPLICAS, APP_DB_POOL_SIZE, and PGBOUNCER_REPLICAS are set, compares application demand to PgBouncer supply using max_client_conn from Prometheus.
    [Tags]    kubernetes    pgbouncer    capacity    access:read-only    data:metrics

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check-capacity-sli.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./check-capacity-sli.sh

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat capacity_sli_analysis.json

    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END

    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=Planned demand should stay below PgBouncer supply with headroom
            ...    actual=Capacity ratio indicates saturation risk or oversubscription
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
        ...    description=Bearer token for Prometheus HTTP API when authentication is required.
        ...    pattern=\w*
        Set Suite Variable    ${PROMETHEUS_BEARER_TOKEN_PATH}    ${prometheus_bearer_token.key}
    EXCEPT
        Log    prometheus_bearer_token secret not provided; queries will be unauthenticated.    WARN
        Set Suite Variable    ${PROMETHEUS_BEARER_TOKEN_PATH}    ${EMPTY}
    END

    ${PROMETHEUS_URL}=    RW.Core.Import User Variable    PROMETHEUS_URL
    ...    type=string
    ...    description=Base URL for Prometheus or Thanos querier API (e.g. https://prom.example/api/v1/).
    ...    pattern=.*
    ...    example=https://prometheus.example/api/v1/

    ${PGBOUNCER_JOB_LABEL}=    RW.Core.Import User Variable    PGBOUNCER_JOB_LABEL
    ...    type=string
    ...    description=Prometheus label matchers for the PgBouncer exporter scrape (inside braces), e.g. job="pgbouncer-exporter".
    ...    pattern=.*
    ...    example=job="pgbouncer-exporter"

    ${EXPECTED_POOL_MODE}=    RW.Core.Import User Variable    EXPECTED_POOL_MODE
    ...    type=string
    ...    description=Expected pool mode (transaction, session, or statement).
    ...    pattern=\w*
    ...    example=transaction

    ${METRIC_NAMESPACE_FILTER}=    RW.Core.Import User Variable    METRIC_NAMESPACE_FILTER
    ...    type=string
    ...    description=Optional Kubernetes namespace label value appended as namespace="..." in PromQL matchers.
    ...    default=
    ...    pattern=.*
    ...    example=my-namespace

    ${CLIENT_SATURATION_PERCENT_THRESHOLD}=    RW.Core.Import User Variable    CLIENT_SATURATION_PERCENT_THRESHOLD
    ...    type=string
    ...    description=Alert when estimated utilization exceeds this percent of max_client_conn.
    ...    default=80
    ...    pattern=\w*

    ${MAX_WAIT_SECONDS_THRESHOLD}=    RW.Core.Import User Variable    MAX_WAIT_SECONDS_THRESHOLD
    ...    type=string
    ...    description=Maximum acceptable pgbouncer_pools_client_maxwait_seconds.
    ...    default=1
    ...    pattern=\w*

    ${CLIENT_WAITING_THRESHOLD}=    RW.Core.Import User Variable    CLIENT_WAITING_THRESHOLD
    ...    type=string
    ...    description=Minimum summed waiting connections to treat as a buildup.
    ...    default=0.5
    ...    pattern=\w*

    ${DATABASE_HOTSPOT_PERCENT_THRESHOLD}=    RW.Core.Import User Variable    DATABASE_HOTSPOT_PERCENT_THRESHOLD
    ...    type=string
    ...    description=Flag a database when its share of summed current_connections exceeds this percent.
    ...    default=40
    ...    pattern=\w*

    ${POD_OUTLIER_DEVIATION_PERCENT}=    RW.Core.Import User Variable    POD_OUTLIER_DEVIATION_PERCENT
    ...    type=string
    ...    description=Percent deviation from median pod load required to flag an outlier pod.
    ...    default=50
    ...    pattern=\w*

    ${CONNECTION_GROWTH_LOOKBACK_MINUTES}=    RW.Core.Import User Variable    CONNECTION_GROWTH_LOOKBACK_MINUTES
    ...    type=string
    ...    description=Lookback window for connection growth range queries.
    ...    default=45
    ...    pattern=\w*

    ${CONNECTION_GROWTH_ABSOLUTE_THRESHOLD}=    RW.Core.Import User Variable    CONNECTION_GROWTH_ABSOLUTE_THRESHOLD
    ...    type=string
    ...    description=Absolute increase in summed client active connections that triggers an issue over the lookback window.
    ...    default=5
    ...    pattern=\w*

    ${CAPACITY_SLI_WARN_RATIO}=    RW.Core.Import User Variable    CAPACITY_SLI_WARN_RATIO
    ...    type=string
    ...    description=Warn when estimated demand divided by supply meets or exceeds this ratio (e.g. 0.85).
    ...    default=0.85
    ...    pattern=\w*

    ${APP_REPLICAS}=    RW.Core.Import User Variable    APP_REPLICAS
    ...    type=string
    ...    description=Application replica count for optional capacity SLI task.
    ...    default=
    ...    pattern=.*

    ${APP_DB_POOL_SIZE}=    RW.Core.Import User Variable    APP_DB_POOL_SIZE
    ...    type=string
    ...    description=Per-replica application DB pool size for optional capacity SLI task.
    ...    default=
    ...    pattern=.*

    ${PGBOUNCER_REPLICAS}=    RW.Core.Import User Variable    PGBOUNCER_REPLICAS
    ...    type=string
    ...    description=PgBouncer Deployment replica count for optional capacity SLI task.
    ...    default=
    ...    pattern=.*

    ${CONTEXT}=    RW.Core.Import User Variable    CONTEXT
    ...    type=string
    ...    description=Kubernetes context name for optional kubectl pairing or documentation.
    ...    default=
    ...    pattern=.*

    Set Suite Variable    ${PROMETHEUS_URL}    ${PROMETHEUS_URL}
    Set Suite Variable    ${PGBOUNCER_JOB_LABEL}    ${PGBOUNCER_JOB_LABEL}
    Set Suite Variable    ${EXPECTED_POOL_MODE}    ${EXPECTED_POOL_MODE}
    Set Suite Variable    ${METRIC_NAMESPACE_FILTER}    ${METRIC_NAMESPACE_FILTER}
    Set Suite Variable    ${CLIENT_SATURATION_PERCENT_THRESHOLD}    ${CLIENT_SATURATION_PERCENT_THRESHOLD}
    Set Suite Variable    ${MAX_WAIT_SECONDS_THRESHOLD}    ${MAX_WAIT_SECONDS_THRESHOLD}
    Set Suite Variable    ${CLIENT_WAITING_THRESHOLD}    ${CLIENT_WAITING_THRESHOLD}
    Set Suite Variable    ${DATABASE_HOTSPOT_PERCENT_THRESHOLD}    ${DATABASE_HOTSPOT_PERCENT_THRESHOLD}
    Set Suite Variable    ${POD_OUTLIER_DEVIATION_PERCENT}    ${POD_OUTLIER_DEVIATION_PERCENT}
    Set Suite Variable    ${CONNECTION_GROWTH_LOOKBACK_MINUTES}    ${CONNECTION_GROWTH_LOOKBACK_MINUTES}
    Set Suite Variable    ${CONNECTION_GROWTH_ABSOLUTE_THRESHOLD}    ${CONNECTION_GROWTH_ABSOLUTE_THRESHOLD}
    Set Suite Variable    ${CAPACITY_SLI_WARN_RATIO}    ${CAPACITY_SLI_WARN_RATIO}
    Set Suite Variable    ${APP_REPLICAS}    ${APP_REPLICAS}
    Set Suite Variable    ${APP_DB_POOL_SIZE}    ${APP_DB_POOL_SIZE}
    Set Suite Variable    ${PGBOUNCER_REPLICAS}    ${PGBOUNCER_REPLICAS}
    Set Suite Variable    ${CONTEXT}    ${CONTEXT}

    ${env}=    Create Dictionary
    ...    PROMETHEUS_URL=${PROMETHEUS_URL}
    ...    PGBOUNCER_JOB_LABEL=${PGBOUNCER_JOB_LABEL}
    ...    METRIC_NAMESPACE_FILTER=${METRIC_NAMESPACE_FILTER}
    ...    EXPECTED_POOL_MODE=${EXPECTED_POOL_MODE}
    ...    CLIENT_SATURATION_PERCENT_THRESHOLD=${CLIENT_SATURATION_PERCENT_THRESHOLD}
    ...    MAX_WAIT_SECONDS_THRESHOLD=${MAX_WAIT_SECONDS_THRESHOLD}
    ...    CLIENT_WAITING_THRESHOLD=${CLIENT_WAITING_THRESHOLD}
    ...    DATABASE_HOTSPOT_PERCENT_THRESHOLD=${DATABASE_HOTSPOT_PERCENT_THRESHOLD}
    ...    POD_OUTLIER_DEVIATION_PERCENT=${POD_OUTLIER_DEVIATION_PERCENT}
    ...    CONNECTION_GROWTH_LOOKBACK_MINUTES=${CONNECTION_GROWTH_LOOKBACK_MINUTES}
    ...    CONNECTION_GROWTH_ABSOLUTE_THRESHOLD=${CONNECTION_GROWTH_ABSOLUTE_THRESHOLD}
    ...    CAPACITY_SLI_WARN_RATIO=${CAPACITY_SLI_WARN_RATIO}
    ...    APP_REPLICAS=${APP_REPLICAS}
    ...    APP_DB_POOL_SIZE=${APP_DB_POOL_SIZE}
    ...    PGBOUNCER_REPLICAS=${PGBOUNCER_REPLICAS}
    ...    CONTEXT=${CONTEXT}
    ...    PROMETHEUS_BEARER_TOKEN=${PROMETHEUS_BEARER_TOKEN_PATH}
    Set Suite Variable    ${env}    ${env}
