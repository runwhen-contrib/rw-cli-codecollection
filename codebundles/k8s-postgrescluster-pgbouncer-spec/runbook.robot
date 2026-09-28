*** Settings ***
Documentation       Audits Crunchy Postgres Operator PostgresCluster specs for PgBouncer proxy settings (pool mode, connection limits, replicas) and optionally compares declared limits to Prometheus metrics.
Metadata            Author    rw-codebundle-agent
Metadata            Display Name    Kubernetes PostgresCluster PgBouncer Spec Audit
Metadata            Supports    Kubernetes PostgresCluster PgBouncer CrunchyData
Force Tags          Kubernetes    PostgresCluster    PgBouncer    CrunchyData

Library             String
Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             RW.K8sHelper

Suite Setup         Suite Initialization


*** Tasks ***
Fetch PostgresCluster PgBouncer Configuration for `${POSTGRESCLUSTER_NAME}` in Namespace `${NAMESPACE}`
    [Documentation]    Reads the PostgresCluster CR and prints spec.proxy.pgBouncer global settings; flags missing proxy blocks or RBAC failures.
    [Tags]    kubernetes    postgres    pgbouncer    config    access:read-only    data:config

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=fetch-postgrescluster-pgbouncer.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./fetch-postgrescluster-pgbouncer.sh

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat fetch_pgbouncer_issues.json
    ...    env=${env}
    ...    include_in_history=false

    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END

    ${n}=    Get Length    ${issue_list}
    IF    ${n} > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue["severity"]}
            ...    expected=PostgresCluster and PgBouncer spec should be readable and declared when pooling is required
            ...    actual=${issue["title"]}
            ...    title=${issue["title"]}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue["details"]}
            ...    next_steps=${issue["next_steps"]}
        END
    END

    RW.Core.Add Pre To Report    Fetch PostgresCluster PgBouncer configuration (stdout from script):
    RW.Core.Add Pre To Report    ${result.stdout}

Validate Pool Mode Matches Expected for `${POSTGRESCLUSTER_NAME}` in Namespace `${NAMESPACE}`
    [Documentation]    Compares spec.proxy.pgBouncer.config.global pool_mode to EXPECTED_POOL_MODE for ORM-appropriate pooling.
    [Tags]    kubernetes    postgres    pgbouncer    pool    access:read-only    data:config

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=validate-pool-mode.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./validate-pool-mode.sh

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat pool_mode_issues.json
    ...    env=${env}
    ...    include_in_history=false

    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END

    ${n}=    Get Length    ${issue_list}
    IF    ${n} > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue["severity"]}
            ...    expected=pool_mode should match policy EXPECTED_POOL_MODE when PgBouncer is enabled
            ...    actual=${issue["title"]}
            ...    title=${issue["title"]}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue["details"]}
            ...    next_steps=${issue["next_steps"]}
        END
    END

    RW.Core.Add Pre To Report    Pool mode validation output:
    RW.Core.Add Pre To Report    ${result.stdout}

Validate Connection Limit Consistency for `${POSTGRESCLUSTER_NAME}` in Namespace `${NAMESPACE}`
    [Documentation]    Checks default_pool_size against max_client_conn and max_db_connections for impossible or risky combinations.
    [Tags]    kubernetes    postgres    pgbouncer    connections    access:read-only    data:config

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=validate-connection-limits.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./validate-connection-limits.sh

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat connection_limits_issues.json
    ...    env=${env}
    ...    include_in_history=false

    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END

    ${n}=    Get Length    ${issue_list}
    IF    ${n} > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue["severity"]}
            ...    expected=PgBouncer global limits should be internally consistent
            ...    actual=${issue["title"]}
            ...    title=${issue["title"]}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue["details"]}
            ...    next_steps=${issue["next_steps"]}
        END
    END

    RW.Core.Add Pre To Report    Connection limit validation output:
    RW.Core.Add Pre To Report    ${result.stdout}

Check PgBouncer Replica Count vs Policy for `${POSTGRESCLUSTER_NAME}` in Namespace `${NAMESPACE}`
    [Documentation]    Compares desired and ready PgBouncer replicas to MIN_PGBOUNCER_REPLICAS for HA expectations.
    [Tags]    kubernetes    postgres    pgbouncer    replicas    ha    access:read-only    data:config

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=validate-pgbouncer-replicas.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./validate-pgbouncer-replicas.sh

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat pgbouncer_replicas_issues.json
    ...    env=${env}
    ...    include_in_history=false

    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END

    ${n}=    Get Length    ${issue_list}
    IF    ${n} > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue["severity"]}
            ...    expected=PgBouncer replicas should meet MIN_PGBOUNCER_REPLICAS when policy requires HA
            ...    actual=${issue["title"]}
            ...    title=${issue["title"]}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue["details"]}
            ...    next_steps=${issue["next_steps"]}
        END
    END

    RW.Core.Add Pre To Report    PgBouncer replica validation output:
    RW.Core.Add Pre To Report    ${result.stdout}

Optional Cross-Check CRD Limits with Live Prometheus Samples for `${POSTGRESCLUSTER_NAME}` in Namespace `${NAMESPACE}`
    [Documentation]    When PROMETHEUS_URL is set, compares CR max_client_conn to recent pgbouncer_config_max_client_connections samples.
    [Tags]    kubernetes    postgres    pgbouncer    prometheus    access:read-only    data:metrics

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=cross-check-crd-vs-metrics.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./cross-check-crd-vs-metrics.sh

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat cross_check_issues.json
    ...    env=${env}
    ...    include_in_history=false

    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END

    ${n}=    Get Length    ${issue_list}
    IF    ${n} > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue["severity"]}
            ...    expected=Declared max_client_conn should match live exporter metrics when Prometheus is available
            ...    actual=${issue["title"]}
            ...    title=${issue["title"]}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue["details"]}
            ...    next_steps=${issue["next_steps"]}
        END
    END

    RW.Core.Add Pre To Report    Prometheus cross-check output:
    RW.Core.Add Pre To Report    ${result.stdout}


*** Keywords ***
Suite Initialization
    ${kubeconfig}=    RW.Core.Import Secret
    ...    kubeconfig
    ...    type=string
    ...    description=Kubernetes credentials with get/list on PostgresCluster and workloads
    ...    pattern=\w*
    ...    example=kubeconfig YAML

    ${CONTEXT}=    RW.Core.Import User Variable    CONTEXT
    ...    type=string
    ...    description=Kubernetes context name
    ...    pattern=\w*
    ...    example=my-cluster

    ${NAMESPACE}=    RW.Core.Import User Variable    NAMESPACE
    ...    type=string
    ...    description=Namespace containing the PostgresCluster
    ...    pattern=\w*
    ...    example=postgres-system

    ${POSTGRESCLUSTER_NAME}=    RW.Core.Import User Variable    POSTGRESCLUSTER_NAME
    ...    type=string
    ...    description=PostgresCluster resource name or All to list all in namespace
    ...    pattern=.*
    ...    example=hippo

    ${EXPECTED_POOL_MODE}=    RW.Core.Import User Variable    EXPECTED_POOL_MODE
    ...    type=string
    ...    description=Expected pool_mode value (transaction, session, or statement)
    ...    pattern=\w*
    ...    example=transaction

    ${MIN_PGBOUNCER_REPLICAS}=    RW.Core.Import User Variable    MIN_PGBOUNCER_REPLICAS
    ...    type=string
    ...    description=Minimum acceptable PgBouncer replicas for policy
    ...    pattern=\w*
    ...    default=1
    ...    example=2

    ${PROMETHEUS_URL}=    RW.Core.Import User Variable    PROMETHEUS_URL
    ...    type=string
    ...    description=Optional Prometheus base URL for metric cross-check (leave empty to skip)
    ...    pattern=.*
    ...    default=
    ...    example=http://prometheus-k8s.monitoring.svc:9090

    ${PROMETHEUS_EXTRA_LABELS}=    RW.Core.Import User Variable    PROMETHEUS_EXTRA_LABELS
    ...    type=string
    ...    description=Optional extra PromQL label selectors appended to the namespace match (e.g. pod=~\"mycluster.*\")
    ...    pattern=.*
    ...    default=
    ...    example=postgres_cluster=\"hippo\"

    ${KUBERNETES_DISTRIBUTION_BINARY}=    RW.Core.Import User Variable    KUBERNETES_DISTRIBUTION_BINARY
    ...    type=string
    ...    description=Kubernetes CLI binary
    ...    pattern=\w*
    ...    default=kubectl
    ...    example=kubectl

    Set Suite Variable    ${kubeconfig}    ${kubeconfig}
    Set Suite Variable    ${CONTEXT}    ${CONTEXT}
    Set Suite Variable    ${NAMESPACE}    ${NAMESPACE}
    Set Suite Variable    ${POSTGRESCLUSTER_NAME}    ${POSTGRESCLUSTER_NAME}
    Set Suite Variable    ${EXPECTED_POOL_MODE}    ${EXPECTED_POOL_MODE}
    Set Suite Variable    ${MIN_PGBOUNCER_REPLICAS}    ${MIN_PGBOUNCER_REPLICAS}
    Set Suite Variable    ${PROMETHEUS_URL}    ${PROMETHEUS_URL}
    Set Suite Variable    ${PROMETHEUS_EXTRA_LABELS}    ${PROMETHEUS_EXTRA_LABELS}
    Set Suite Variable    ${KUBERNETES_DISTRIBUTION_BINARY}    ${KUBERNETES_DISTRIBUTION_BINARY}

    ${env}=    Create Dictionary
    ...    CONTEXT=${CONTEXT}
    ...    NAMESPACE=${NAMESPACE}
    ...    POSTGRESCLUSTER_NAME=${POSTGRESCLUSTER_NAME}
    ...    EXPECTED_POOL_MODE=${EXPECTED_POOL_MODE}
    ...    MIN_PGBOUNCER_REPLICAS=${MIN_PGBOUNCER_REPLICAS}
    ...    PROMETHEUS_URL=${PROMETHEUS_URL}
    ...    PROMETHEUS_EXTRA_LABELS=${PROMETHEUS_EXTRA_LABELS}
    ...    KUBERNETES_DISTRIBUTION_BINARY=${KUBERNETES_DISTRIBUTION_BINARY}
    ...    KUBECONFIG=./${kubeconfig.key}
    Set Suite Variable    ${env}    ${env}

    RW.K8sHelper.Verify Cluster Connectivity
    ...    binary=${KUBERNETES_DISTRIBUTION_BINARY}
    ...    context=${CONTEXT}
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
