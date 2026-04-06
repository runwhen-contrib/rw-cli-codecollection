*** Settings ***
Documentation       Audits Crunchy Postgres Operator PostgresCluster specifications for the PgBouncer proxy block (pool mode, connection limits, replicas) and optionally cross-checks Prometheus metrics.
Metadata            Author    rw-codebundle-agent
Metadata            Display Name    Kubernetes PostgresCluster PgBouncer Spec Audit
Metadata            Supports    Kubernetes    Postgres    Crunchy    PgBouncer    Config

Library             String
Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             RW.K8sHelper
Library             Collections

Force Tags          Kubernetes    Postgres    PgBouncer    Crunchy    Config

Suite Setup         Suite Initialization


*** Tasks ***
Fetch PostgresCluster PgBouncer Configuration for `${POSTGRESCLUSTER_NAME}` in Namespace `${NAMESPACE}`
    [Documentation]    Reads the PostgresCluster CR and prints spec.proxy.pgBouncer (and status) for the target cluster or all clusters when POSTGRESCLUSTER_NAME is All.
    [Tags]    kubernetes    postgres    pgbouncer    config    access:read-only    data:config

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=fetch-postgrescluster-pgbouncer.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    timeout_seconds=180
    ...    include_in_history=False
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=CONTEXT=${CONTEXT} NAMESPACE=${NAMESPACE} POSTGRESCLUSTER_NAME=${POSTGRESCLUSTER_NAME} ./fetch-postgrescluster-pgbouncer.sh

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat fetch_pgbouncer_issues.json
    ...    env=${env}

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
            ...    expected=PostgresCluster CR should be readable and declare PgBouncer when pooling is required
            ...    actual=${issue['details']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END

    RW.Core.Add Pre To Report    Fetch PostgresCluster PgBouncer configuration
    RW.Core.Add Pre To Report    ${result.stdout}

Validate Pool Mode Matches Expected for `${POSTGRESCLUSTER_NAME}` in Namespace `${NAMESPACE}`
    [Documentation]    Compares spec.proxy.pgBouncer.poolMode to EXPECTED_POOL_MODE for ORM-appropriate pooling (transaction, session, or statement).
    [Tags]    kubernetes    postgres    pgbouncer    poolmode    access:read-only    data:config

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=validate-pool-mode.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    timeout_seconds=180
    ...    include_in_history=False
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=EXPECTED_POOL_MODE=${EXPECTED_POOL_MODE} ./validate-pool-mode.sh

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat pool_mode_issues.json
    ...    env=${env}

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
            ...    expected=poolMode should match EXPECTED_POOL_MODE (${EXPECTED_POOL_MODE})
            ...    actual=${issue['details']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END

    RW.Core.Add Pre To Report    Pool mode validation output
    RW.Core.Add Pre To Report    ${result.stdout}

Validate Connection Limit Consistency for `${POSTGRESCLUSTER_NAME}` in Namespace `${NAMESPACE}`
    [Documentation]    Checks max_client_conn, default_pool_size, and max_db_connections for impossible or risky combinations declared in the PgBouncer config block.
    [Tags]    kubernetes    postgres    pgbouncer    limits    access:read-only    data:config

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=validate-connection-limits.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    timeout_seconds=180
    ...    include_in_history=False
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./validate-connection-limits.sh

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat connection_limits_issues.json
    ...    env=${env}

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
            ...    expected=Pgbouncer connection limits should be internally consistent
            ...    actual=${issue['details']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END

    RW.Core.Add Pre To Report    Connection limit validation output
    RW.Core.Add Pre To Report    ${result.stdout}

Check PgBouncer Replica Count vs Policy for `${POSTGRESCLUSTER_NAME}` in Namespace `${NAMESPACE}`
    [Documentation]    Compares observed or declared PgBouncer replicas to MIN_PGBOUNCER_REPLICAS using status, spec, or pod counts.
    [Tags]    kubernetes    postgres    pgbouncer    replicas    ha    access:read-only    data:config

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=validate-pgbouncer-replicas.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    timeout_seconds=180
    ...    include_in_history=False
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=MIN_PGBOUNCER_REPLICAS=${MIN_PGBOUNCER_REPLICAS} ./validate-pgbouncer-replicas.sh

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat replica_issues.json
    ...    env=${env}

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
            ...    expected=Pgbouncer replicas should meet MIN_PGBOUNCER_REPLICAS (${MIN_PGBOUNCER_REPLICAS})
            ...    actual=${issue['details']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END

    RW.Core.Add Pre To Report    PgBouncer replica validation output
    RW.Core.Add Pre To Report    ${result.stdout}

Optional Cross-Check CRD Limits with Live Prometheus Samples for `${POSTGRESCLUSTER_NAME}`
    [Documentation]    When PROMETHEUS_URL is set, compares CR max_client_conn to pgbouncer_config_max_client_connections; skipped when URL is unset.
    [Tags]    kubernetes    postgres    pgbouncer    prometheus    metrics    access:read-only    data:metrics

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=cross-check-crd-vs-metrics.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    timeout_seconds=180
    ...    include_in_history=False
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=PROMETHEUS_URL=${PROMETHEUS_URL} ./cross-check-crd-vs-metrics.sh

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat prometheus_crosscheck_issues.json
    ...    env=${env}

    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for Prometheus cross-check, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END

    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=Prometheus pgbouncer_config_max_client_connections should match CR max_client_conn when metrics exist
            ...    actual=${issue['details']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END

    RW.Core.Add Pre To Report    Prometheus cross-check output
    RW.Core.Add Pre To Report    ${result.stdout}


*** Keywords ***
Suite Initialization
    ${kubeconfig}=    RW.Core.Import Secret
    ...    kubeconfig
    ...    type=string
    ...    description=Kubernetes kubeconfig with get/list on PostgresCluster and workloads.
    ...    pattern=\w*

    ${CONTEXT}=    RW.Core.Import User Variable    CONTEXT
    ...    type=string
    ...    description=Kubernetes context name.
    ...    pattern=\w*
    ${NAMESPACE}=    RW.Core.Import User Variable    NAMESPACE
    ...    type=string
    ...    description=Namespace containing the PostgresCluster.
    ...    pattern=\w*
    ${POSTGRESCLUSTER_NAME}=    RW.Core.Import User Variable    POSTGRESCLUSTER_NAME
    ...    type=string
    ...    description=PostgresCluster resource name, or All to audit every PostgresCluster in the namespace.
    ...    pattern=\w*
    ${EXPECTED_POOL_MODE}=    RW.Core.Import User Variable    EXPECTED_POOL_MODE
    ...    type=string
    ...    description=Expected PgBouncer pool mode (transaction, session, or statement).
    ...    pattern=\w*
    ${MIN_PGBOUNCER_REPLICAS}=    RW.Core.Import User Variable    MIN_PGBOUNCER_REPLICAS
    ...    type=string
    ...    description=Minimum acceptable PgBouncer replicas for policy.
    ...    pattern=\w*
    ...    default=1
    ${PROMETHEUS_URL}=    RW.Core.Import User Variable    PROMETHEUS_URL
    ...    type=string
    ...    description=Optional Prometheus base URL for max_client_conn cross-check (e.g. https://prometheus.example.com).
    ...    pattern=.*
    ...    default=${EMPTY}
    ${KUBERNETES_DISTRIBUTION_BINARY}=    RW.Core.Import User Variable    KUBERNETES_DISTRIBUTION_BINARY
    ...    type=string
    ...    description=Kubernetes CLI binary to use.
    ...    enum=[kubectl,oc]
    ...    default=kubectl

    Set Suite Variable    ${kubeconfig}    ${kubeconfig}
    Set Suite Variable    ${CONTEXT}    ${CONTEXT}
    Set Suite Variable    ${NAMESPACE}    ${NAMESPACE}
    Set Suite Variable    ${POSTGRESCLUSTER_NAME}    ${POSTGRESCLUSTER_NAME}
    Set Suite Variable    ${EXPECTED_POOL_MODE}    ${EXPECTED_POOL_MODE}
    Set Suite Variable    ${MIN_PGBOUNCER_REPLICAS}    ${MIN_PGBOUNCER_REPLICAS}
    Set Suite Variable    ${PROMETHEUS_URL}    ${PROMETHEUS_URL}
    Set Suite Variable    ${KUBERNETES_DISTRIBUTION_BINARY}    ${KUBERNETES_DISTRIBUTION_BINARY}

    ${env}=    Create Dictionary
    ...    CONTEXT=${CONTEXT}
    ...    NAMESPACE=${NAMESPACE}
    ...    POSTGRESCLUSTER_NAME=${POSTGRESCLUSTER_NAME}
    ...    EXPECTED_POOL_MODE=${EXPECTED_POOL_MODE}
    ...    MIN_PGBOUNCER_REPLICAS=${MIN_PGBOUNCER_REPLICAS}
    ...    PROMETHEUS_URL=${PROMETHEUS_URL}
    ...    KUBERNETES_DISTRIBUTION_BINARY=${KUBERNETES_DISTRIBUTION_BINARY}
    ...    KUBECONFIG=./${kubeconfig.key}
    Set Suite Variable    ${env}    ${env}

    RW.K8sHelper.Verify Cluster Connectivity
    ...    binary=${KUBERNETES_DISTRIBUTION_BINARY}
    ...    context=${CONTEXT}
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
