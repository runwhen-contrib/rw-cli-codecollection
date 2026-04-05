*** Settings ***
Documentation       Validates Crunchy Postgres Operator PostgresCluster PgBouncer proxy settings (pool mode, connection limits, replicas) and optionally cross-checks declared limits against Prometheus.
Metadata            Author    rw-codebundle-agent
Metadata            Display Name    Kubernetes PostgresCluster PgBouncer Spec Audit
Metadata            Supports    Kubernetes PostgresCluster PgBouncer Crunchy PGO

Library             String
Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform

Force Tags          Kubernetes    PostgresCluster    PgBouncer    Crunchy    Config

Suite Setup         Suite Initialization


*** Tasks ***
Fetch PostgresCluster PgBouncer Configuration for `${POSTGRESCLUSTER_NAME}` in Namespace `${NAMESPACE}`
    [Documentation]    Reads the PostgresCluster CR and prints spec.proxy.pgBouncer; raises issues if the CR is unreadable or PgBouncer is not configured.
    [Tags]    Kubernetes    PostgresCluster    PgBouncer    access:read-only    data:config

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=fetch-postgrescluster-pgbouncer.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./fetch-postgrescluster-pgbouncer.sh

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat fetch_issues.json
    ...    env=${env}
    ...    include_in_history=false

    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for fetch task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END

    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=PostgresCluster is readable and declares spec.proxy.pgBouncer when pooling is required
            ...    actual=${issue['title']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END

    RW.Core.Add Pre To Report    PgBouncer spec fetch output:\n${result.stdout}

Validate Pool Mode Matches Expected for `${POSTGRESCLUSTER_NAME}` in Namespace `${NAMESPACE}`
    [Documentation]    Compares spec.proxy.pgBouncer.config.global.pool_mode to EXPECTED_POOL_MODE for ORM-appropriate pooling.
    [Tags]    Kubernetes    PostgresCluster    PgBouncer    access:read-only    data:config

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=validate-pool-mode.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=false
    ...    cmd_override=./validate-pool-mode.sh

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat pool_mode_issues.json
    ...    env=${env}
    ...    include_in_history=false

    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for pool mode task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END

    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=pool_mode should match EXPECTED_POOL_MODE (${EXPECTED_POOL_MODE})
            ...    actual=${issue['title']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END

    RW.Core.Add Pre To Report    Pool mode validation:\n${result.stdout}

Validate Connection Limit Consistency for `${POSTGRESCLUSTER_NAME}` in Namespace `${NAMESPACE}`
    [Documentation]    Checks relationships among default_pool_size, max_client_conn, and max_db_connections in the PgBouncer global configuration.
    [Tags]    Kubernetes    PostgresCluster    PgBouncer    access:read-only    data:config

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=validate-connection-limits.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=false
    ...    cmd_override=./validate-connection-limits.sh

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat connection_limits_issues.json
    ...    env=${env}
    ...    include_in_history=false

    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for connection limits task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END

    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=PgBouncer global limits should be internally consistent
            ...    actual=${issue['title']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END

    RW.Core.Add Pre To Report    Connection limits validation:\n${result.stdout}

Check PgBouncer Replica Count for `${POSTGRESCLUSTER_NAME}` in Namespace `${NAMESPACE}`
    [Documentation]    Compares observed PgBouncer replicas (CR status or Deployment) to MIN_PGBOUNCER_REPLICAS.
    [Tags]    Kubernetes    PostgresCluster    PgBouncer    access:read-only    data:config

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=validate-pgbouncer-replicas.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=false
    ...    cmd_override=./validate-pgbouncer-replicas.sh

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat replica_issues.json
    ...    env=${env}
    ...    include_in_history=false

    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for replica task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END

    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=PgBouncer ready replicas should be at least MIN_PGBOUNCER_REPLICAS (${MIN_PGBOUNCER_REPLICAS})
            ...    actual=${issue['title']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END

    RW.Core.Add Pre To Report    Replica validation:\n${result.stdout}

Optional Cross-Check CRD Limits with Live Prometheus Samples for `${POSTGRESCLUSTER_NAME}`
    [Documentation]    When PROMETHEUS_URL and PROMETHEUS_LABEL_SELECTOR are set, compares CR max_client_conn to a recent Prometheus sample.
    [Tags]    Kubernetes    PostgresCluster    PgBouncer    Prometheus    access:read-only    data:metrics

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=cross-check-crd-vs-metrics.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=false
    ...    cmd_override=./cross-check-crd-vs-metrics.sh

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat metrics_crosscheck_issues.json
    ...    env=${env}
    ...    include_in_history=false

    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for Prometheus cross-check task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END

    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=Prometheus max_client_conn sample should match PostgresCluster CR when labels align
            ...    actual=${issue['title']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END

    RW.Core.Add Pre To Report    Prometheus cross-check:\n${result.stdout}


*** Keywords ***
Suite Initialization
    ${kubeconfig}=    RW.Core.Import Secret
    ...    kubeconfig
    ...    type=string
    ...    description=Kubernetes credentials with get/list on PostgresCluster and workloads
    ...    pattern=\w*
    ${KUBERNETES_DISTRIBUTION_BINARY}=    RW.Core.Import User Variable    KUBERNETES_DISTRIBUTION_BINARY
    ...    type=string
    ...    description=Kubernetes CLI binary
    ...    default=kubectl
    ...    pattern=\w*
    ${CONTEXT}=    RW.Core.Import User Variable    CONTEXT
    ...    type=string
    ...    description=Kubernetes context name
    ...    pattern=\w*
    ${NAMESPACE}=    RW.Core.Import User Variable    NAMESPACE
    ...    type=string
    ...    description=Namespace containing the PostgresCluster
    ...    pattern=\w*
    ${POSTGRESCLUSTER_NAME}=    RW.Core.Import User Variable    POSTGRESCLUSTER_NAME
    ...    type=string
    ...    description=PostgresCluster name or All for discovery
    ...    pattern=\w*
    ${EXPECTED_POOL_MODE}=    RW.Core.Import User Variable    EXPECTED_POOL_MODE
    ...    type=string
    ...    description=Expected pool mode (transaction, session, statement)
    ...    pattern=\w*
    ${MIN_PGBOUNCER_REPLICAS}=    RW.Core.Import User Variable    MIN_PGBOUNCER_REPLICAS
    ...    type=string
    ...    description=Minimum acceptable PgBouncer replicas
    ...    default=1
    ...    pattern=\w*
    ${PROMETHEUS_URL}=    RW.Core.Import User Variable    PROMETHEUS_URL
    ...    type=string
    ...    description=Optional Prometheus base URL for cross-check
    ...    default=
    ...    pattern=\w*
    ${PROMETHEUS_LABEL_SELECTOR}=    RW.Core.Import User Variable    PROMETHEUS_LABEL_SELECTOR
    ...    type=string
    ...    description=Label selector inside metric braces for cross-check (optional)
    ...    default=
    ...    pattern=\w*
    ${PROMETHEUS_MAX_CLIENT_CONN_METRIC}=    RW.Core.Import User Variable    PROMETHEUS_MAX_CLIENT_CONN_METRIC
    ...    type=string
    ...    description=Metric name for max_client_conn instant query
    ...    default=pgbouncer_config_max_client_connections
    ...    pattern=\w*
    Set Suite Variable    ${kubeconfig}    ${kubeconfig}
    Set Suite Variable    ${CONTEXT}    ${CONTEXT}
    Set Suite Variable    ${NAMESPACE}    ${NAMESPACE}
    Set Suite Variable    ${POSTGRESCLUSTER_NAME}    ${POSTGRESCLUSTER_NAME}
    Set Suite Variable    ${EXPECTED_POOL_MODE}    ${EXPECTED_POOL_MODE}
    Set Suite Variable    ${MIN_PGBOUNCER_REPLICAS}    ${MIN_PGBOUNCER_REPLICAS}
    Set Suite Variable    ${PROMETHEUS_URL}    ${PROMETHEUS_URL}
    Set Suite Variable    ${PROMETHEUS_LABEL_SELECTOR}    ${PROMETHEUS_LABEL_SELECTOR}
    Set Suite Variable    ${PROMETHEUS_MAX_CLIENT_CONN_METRIC}    ${PROMETHEUS_MAX_CLIENT_CONN_METRIC}
    Set Suite Variable    ${KUBERNETES_DISTRIBUTION_BINARY}    ${KUBERNETES_DISTRIBUTION_BINARY}
    ${env}=    Create Dictionary
    ...    CONTEXT=${CONTEXT}
    ...    NAMESPACE=${NAMESPACE}
    ...    POSTGRESCLUSTER_NAME=${POSTGRESCLUSTER_NAME}
    ...    EXPECTED_POOL_MODE=${EXPECTED_POOL_MODE}
    ...    MIN_PGBOUNCER_REPLICAS=${MIN_PGBOUNCER_REPLICAS}
    ...    PROMETHEUS_URL=${PROMETHEUS_URL}
    ...    PROMETHEUS_LABEL_SELECTOR=${PROMETHEUS_LABEL_SELECTOR}
    ...    PROMETHEUS_MAX_CLIENT_CONN_METRIC=${PROMETHEUS_MAX_CLIENT_CONN_METRIC}
    ...    KUBERNETES_DISTRIBUTION_BINARY=${KUBERNETES_DISTRIBUTION_BINARY}
    ...    KUBECONFIG=./${kubeconfig.key}
    Set Suite Variable    ${env}    ${env}
