*** Settings ***
Documentation       Runs a series of tasks to check the overall health of a postgres cluster and to provide detailed information useful for debugging or reviewing configurations. 
Metadata            Author    stewartshea
Metadata            Display Name    Kubernetes Postgres Healthcheck
Metadata            Supports    AKS,EKS,GKE,Kubernetes,Patroni,Postgres,Crunchy,Zalando

Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             RW.K8sHelper
Library             String
Library             Collections
Library             DateTime

Suite Setup         Suite Initialization


*** Tasks ***
List Resources Related to Postgres Cluster `${OBJECT_NAME}` in Namespace `${NAMESPACE}`
    [Documentation]    Runs a simple fetch all for the resources in the given workspace under the configured labels.
    [Tags]    access:read-only    postgres    resources    workloads    standard    information    data:config
    ${resources}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get all -l ${RESOURCE_LABELS} -n ${NAMESPACE} --context ${CONTEXT} && ${KUBERNETES_DISTRIBUTION_BINARY} describe ${OBJECT_KIND} ${OBJECT_NAME} -n ${NAMESPACE} --context ${CONTEXT}
    ...    env=${env}
    ...    secret_file__kubeconfig=${KUBECONFIG}
    ...    show_in_rwl_cheatsheet=true
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    ${resources.stdout}
    RW.Core.Add Pre To Report    Commands Used:\n${history}

Get Postgres Pod Logs & Events for Cluster `${OBJECT_NAME}` in Namespace `${NAMESPACE}`
    [Documentation]    Queries Postgres-related pods for their recent logs and checks for any warning-type events.
    [Tags]    access:read-only    postgres    events    warnings    labels    logs    errors    pods    data:logs-bulk
    ${labeled_pods}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get pods -l ${RESOURCE_LABELS} -n ${NAMESPACE} --context ${CONTEXT} -o=name --field-selector=status.phase=Running
    ...    env=${env}
    ...    secret_file__kubeconfig=${KUBECONFIG}
    ...    show_in_rwl_cheatsheet=true
    ...    render_in_commandlist=true
    ${labeled_pod_names}=    Split String    ${labeled_pods.stdout}
    ${found_pod_logs}=    Set Variable    No logs found!
    ${found_pod_events}=    Set Variable    No events found!
    IF    len(${labeled_pod_names}) > 0
        ${temp_logs}=    RW.CLI.Run Cli
        ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} logs {item} -n ${NAMESPACE} --context ${CONTEXT} -c ${DATABASE_CONTAINER} --tail=100
        ...    env=${env}
        ...    secret_file__kubeconfig=${KUBECONFIG}
        ...    loop_with_items=${labeled_pod_names}

        ${involved_pod_names}=    Evaluate    [full_name.split("/")[-1] for full_name in ${labeled_pod_names}]
        ${temp_events}=    RW.CLI.Run Cli
        ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get events -n ${NAMESPACE} --context ${CONTEXT} --field-selector involvedObject.name={item}
        ...    env=${env}
        ...    secret_file__kubeconfig=${KUBECONFIG}
        ...    loop_with_items=${involved_pod_names}

        ${found_pod_logs}=    Evaluate
        ...    """${temp_logs.stdout}""" if """${temp_logs.stdout}""" else "${found_pod_logs}"
        ${found_pod_events}=    Evaluate
        ...    """${temp_events.stdout}""" if """${temp_events.stdout}""" else "${found_pod_events}"
    END
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Log Results:\n${found_pod_logs}
    RW.Core.Add Pre To Report    Event Results:\n${found_pod_events}
    RW.Core.Add Pre To Report    Commands Used:\n${history}

Get Postgres Pod Resource Utilization for Cluster `${OBJECT_NAME}` in Namespace `${NAMESPACE}`
    [Documentation]    Performs and a top command on list of labeled postgres-related workloads to check pod resources.
    [Tags]    access:read-only    top    resources    utilization    database    workloads    cpu    memory    allocation    postgres    data:config
    ${container_resource_utilization}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} top pods -l ${RESOURCE_LABELS} --containers -n ${NAMESPACE} --context ${CONTEXT}
    ...    env=${env}
    ...    secret_file__kubeconfig=${KUBECONFIG}
    ...    show_in_rwl_cheatsheet=true
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Pod Resource Utilization:\n${container_resource_utilization.stdout}
    RW.Core.Add Pre To Report    Commands Used:\n${history}

Check PostgreSQL Connection Health for Cluster `${OBJECT_NAME}` in Namespace `${NAMESPACE}`
    [Documentation]    Checks connection utilization, client connection summaries, and detects connection saturation issues. Prefers running queries from replicas for safety.
    [Tags]    access:read-only    postgres    connections    utilization    health    clients    saturation    data:config
    ${connection_health}=    RW.CLI.Run Bash File
    ...    bash_file=connection_health.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    include_in_history=False
    ...    show_in_rwl_cheatsheet=true
    ${full_report}=    RW.CLI.Run CLI
    ...    cmd=cat ../connection_health_report.out
    ${issues}=    RW.CLI.Run CLI
    ...    cmd=awk '/Issues:/ {flag=1; next} flag {print}' ../connection_health_report.out | head -n -0
    ${issues_json}=    Evaluate    json.loads(r'''${issues.stdout}''') if r'''${issues.stdout}'''.strip() and r'''${issues.stdout}'''.strip() != '[]' else []    json
    ${issue_timestamp}=    DateTime.Get Current Date
    IF    len(@{issues_json}) > 0
        FOR    ${item}    IN    @{issues_json}
            ${severity}=    Evaluate    ${item}.get("severity", 3)
            ${next_steps}=    Evaluate    ${item}.get('next_steps', 'Investigate connection health issues')
            RW.Core.Add Issue
            ...    severity=${severity}
            ...    expected=Connection health for \`${OBJECT_NAME}\` in \`${NAMESPACE}\` should be within acceptable thresholds.
            ...    actual=${item["description"]}
            ...    title=${item["title"]}
            ...    reproduce_hint=${connection_health.cmd}
            ...    details=${item}
            ...    next_steps=${next_steps}
            ...    observed_at=${issue_timestamp}
        END
    END
    RW.Core.Add Pre To Report    Commands Used:\n${connection_health.cmd}
    RW.Core.Add Pre To Report    ${full_report.stdout}

Check PostgreSQL Core Metrics for Cluster `${OBJECT_NAME}` in Namespace `${NAMESPACE}`
    [Documentation]    Checks storage utilization, database sizes, table bloat, WAL usage, and other core PostgreSQL metrics.
    [Tags]    access:read-only    postgres    storage    metrics    health    disk    wal    bloat    data:config
    ${core_metrics}=    RW.CLI.Run Bash File
    ...    bash_file=core_metrics.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    include_in_history=False
    ...    show_in_rwl_cheatsheet=true
    ${full_report}=    RW.CLI.Run CLI
    ...    cmd=cat ../core_metrics_report.out
    ${issues}=    RW.CLI.Run CLI
    ...    cmd=awk '/Issues:/ {flag=1; next} flag {print}' ../core_metrics_report.out | head -n -0
    ${issues_json}=    Evaluate    json.loads(r'''${issues.stdout}''') if r'''${issues.stdout}'''.strip() and r'''${issues.stdout}'''.strip() != '[]' else []    json
    ${issue_timestamp}=    DateTime.Get Current Date
    IF    len(@{issues_json}) > 0
        FOR    ${item}    IN    @{issues_json}
            ${severity}=    Evaluate    ${item}.get("severity", 3)
            ${next_steps}=    Evaluate    ${item}.get('next_steps', 'Investigate storage and metrics issues')
            RW.Core.Add Issue
            ...    severity=${severity}
            ...    expected=Core metrics for \`${OBJECT_NAME}\` in \`${NAMESPACE}\` should be within acceptable thresholds.
            ...    actual=${item["description"]}
            ...    title=${item["title"]}
            ...    reproduce_hint=${core_metrics.cmd}
            ...    details=${item}
            ...    next_steps=${next_steps}
            ...    observed_at=${issue_timestamp}
        END
    END
    RW.Core.Add Pre To Report    Commands Used:\n${core_metrics.cmd}
    RW.Core.Add Pre To Report    ${full_report.stdout}

Get Running Postgres Configuration for Cluster `${OBJECT_NAME}` in Namespace `${NAMESPACE}`
    [Documentation]    Fetches the postgres instance's configuration information.
    [Tags]    access:read-only    config    postgres    file    show    path    setup    configuration    data:config
    ${config_health}=    RW.CLI.Run Bash File
    ...    bash_file=config_health.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    include_in_history=False
    ...    show_in_rwl_cheatsheet=true
    ${full_report}=    RW.CLI.Run CLI
    ...    cmd=cat ../config_report.out
    ${issues}=    RW.CLI.Run CLI
    ...    cmd=awk '/Issues:/ {flag=1; next} /Backup Report:/ {flag=0} flag {print}' ../config_report.out
    ${issues_json}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    ${issue_timestamp}=    DateTime.Get Current Date
    IF    len(@{issues_json}) > 0
        FOR    ${item}    IN    @{issues_json}
            RW.Core.Add Issue
            ...    severity=4
            ...    expected=Configuration issues for `${OBJECT_NAME}` in `${NAMESPACE}` should not be present.
            ...    actual=${item["description"]}
            ...    title=${item["title"]}
            ...    reproduce_hint=${config_health.cmd}
            ...    details=${item}
            ...    next_steps=Restart PostgreSQL Cluster with Rolling Update for `${OBJECT_NAME}` in `${NAMESPACE}`\nEscalate database configuration issues to service owner of `${OBJECT_NAME}` in namespace `${NAMESPACE}`
            ...    observed_at=${issue_timestamp}
        END
    END
    RW.Core.Add Pre To Report    Commands Used:\n${config_health.cmd}
    RW.Core.Add Pre To Report    ${config_health.stdout}

Get Patroni Output and Add to Report for Cluster `${OBJECT_NAME}` in Namespace `${NAMESPACE}`
    [Documentation]    Attempts to run the patronictl CLI within the workload if it's available to check the current state of a patroni cluster, if applicable.
    [Tags]    access:read-only    patroni    patronictl    list    cluster    health    check    state    postgres    data:config
    ${patroni_output}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} exec $(${KUBERNETES_DISTRIBUTION_BINARY} get pods ${WORKLOAD_NAME} -n ${NAMESPACE} --context ${CONTEXT} -o jsonpath='{.items[0].metadata.name}') -n ${NAMESPACE} --context ${CONTEXT} -c ${DATABASE_CONTAINER} -- patronictl list
    ...    env=${env}
    ...    secret_file__kubeconfig=${KUBECONFIG}
    ...    show_in_rwl_cheatsheet=true
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Patroni Output:\n${patroni_output.stdout}
    RW.Core.Add Pre To Report    Commands Used:\n${history}

Fetch Patroni Database Lag for Cluster `${OBJECT_NAME}` in Namespace `${NAMESPACE}`
    [Documentation]    Identifies the lag using patronictl and raises issues if necessary.
    [Tags]    access:read-only    patroni    patronictl    list    cluster    health    postgres    lag    data:config
    ${patroni_output}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} exec $(${KUBERNETES_DISTRIBUTION_BINARY} get pods ${WORKLOAD_NAME} -n ${NAMESPACE} --context ${CONTEXT} -o jsonpath='{.items[0].metadata.name}') -n ${NAMESPACE} --context ${CONTEXT} -c ${DATABASE_CONTAINER} -- patronictl list -f json
    ...    env=${env}
    ...    secret_file__kubeconfig=${KUBECONFIG}
    ...    show_in_rwl_cheatsheet=true
    ${patroni_members}=    Evaluate    json.loads(r'''${patroni_output.stdout}''')    json
    ${issue_timestamp}=    DateTime.Get Current Date
    IF    len(@{patroni_members}) > 0
        FOR    ${item}    IN    @{patroni_members}
            IF    "Lag in MB" not in ${item}    CONTINUE
            ${lag_in_mb}=    Get From Dictionary    ${item}    Lag in MB
            IF    ${lag_in_mb} > ${DATABASE_LAG_THRESHOLD}
                RW.Core.Add Issue
                ...    severity=1
                ...    expected=Database cluster `${item["Cluster"]}` in `${NAMESPACE}` should have a lag below ${DATABASE_LAG_THRESHOLD} MB
                ...    actual=Database cluster `${item["Cluster"]}` in `${NAMESPACE}` has lag above ${DATABASE_LAG_THRESHOLD} MB
                ...    title=Database member `${item["Member"]}` in Cluster `${item["Cluster"]}` has lag of ${lag_in_mb} MB in `${NAMESPACE}`
                ...    reproduce_hint=${patroni_output.cmd}
                ...    details=${patroni_output.stdout}
                ...    next_steps=Reinitialize Failed PostgreSQL Cluster Members for `${item["Cluster"]}` in `${NAMESPACE}`\nCheck PostgreSQL Replication Status for `${item["Cluster"]}` in `${NAMESPACE}`\nFetch the Storage Utilization for PVC Mounts in Namespace `${NAMESPACE}`
                ...    observed_at=${issue_timestamp}
            END
        END
    END
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    ${patroni_output.stdout}

Check Database Backup Status for Cluster `${OBJECT_NAME}` in Namespace `${NAMESPACE}`
    [Documentation]    Checks the status of backup operations on Kubernets Postgres clusters. Raises issues if backups have not been completed or appear unhealthy.
    [Tags]    access:read-only    patroni    cluster    health    backup    database    postgres    data:config
    ${backup_health}=    RW.CLI.Run Bash File
    ...    bash_file=backup_health.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    include_in_history=False
    ...    show_in_rwl_cheatsheet=true
    ${full_report}=    RW.CLI.Run CLI
    ...    cmd=cat ../backup_report.out
    ${issues}=    RW.CLI.Run CLI
    ...    cmd=awk '/Issues:/ {flag=1; next} /Backup Report:/ {flag=0} flag {print}' ../backup_report.out
    ${issues_json}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    ${issue_timestamp}=    DateTime.Get Current Date
    IF    len(@{issues_json}) > 0
        FOR    ${item}    IN    @{issues_json}
            RW.Core.Add Issue
            ...    severity=3
            ...    expected=Database backups for `${OBJECT_NAME}` in `${NAMESPACE}` should be completed in the last 24 hours
            ...    actual=${item["description"]}
            ...    title=${item["title"]}
            ...    reproduce_hint=${backup_health.cmd}
            ...    details=${item}
            ...    next_steps=Restart PostgreSQL Cluster with Rolling Update for `${OBJECT_NAME}` in `${NAMESPACE}`\nFetch the Storage Utilization for PVC Mounts in Namespace `${NAMESPACE}`\nCheck Postgres archive settings from running configuration in Cluster `${OBJECT_NAME}` in Namespace `${NAMESPACE}`
            ...    observed_at=${issue_timestamp}
        END
    END
    RW.Core.Add Pre To Report    ${full_report.stdout}

Run DB Queries for Cluster `${OBJECT_NAME}` in Namespace `${NAMESPACE}`
    [Documentation]    Runs a suite of configurable queries to check for index issues, slow-queries, etc and create a report.
    [Tags]    access:read-only    slow queries    index    health    triage    postgres    patroni    tables    data:config
    ${dbquery}=    RW.CLI.Run Bash File
    ...    bash_file=dbquery.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    include_in_history=False
    ...    show_in_rwl_cheatsheet=true
    ${full_report}=    RW.CLI.Run CLI
    ...    cmd=cat ../health_query_report.out
    ${issues}=    RW.CLI.Run CLI
    ...    cmd=awk '/Issues:/ {flag=1; next} /Backup Report:/ {flag=0} flag {print}' ../health_query_report.out
    ${issues_json}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    ${issue_timestamp}=    DateTime.Get Current Date
    IF    len(@{issues_json}) > 0
        FOR    ${item}    IN    @{issues_json}
            RW.Core.Add Issue
            ...    severity=3
            ...    expected=Datbase Query for `${OBJECT_NAME}` in `${NAMESPACE}` should execute successfully.
            ...    actual=${item["description"]}
            ...    title=${item["title"]}
            ...    reproduce_hint=${dbquery.cmd}
            ...    details=${item}
            ...    next_steps=Reinitialize Failed PostgreSQL Cluster Members for `${OBJECT_NAME}` in `${NAMESPACE}`\nRestart PostgreSQL Cluster with Rolling Update for `${OBJECT_NAME}` in `${NAMESPACE}`\nVerify the database query for postgres cluster `${OBJECT_NAME}` in `${NAMESPACE}`\nCheck Deployment or StatefulSet Health for `${OBJECT_NAME}` in Namespace `${NAMESPACE}`
            ...    observed_at=${issue_timestamp}
        END
    END
    RW.Core.Add Pre To Report    ${full_report.stdout}

*** Keywords ***
Suite Initialization
    ${kubeconfig}=    RW.Core.Import Secret
    ...    kubeconfig
    ...    type=string
    ...    description=The kubernetes kubeconfig yaml containing connection configuration used to connect to cluster(s).
    ...    pattern=\w*
    ...    example=For examples, start here https://kubernetes.io/docs/concepts/configuration/organize-cluster-access-kubeconfig/

    ${CONTEXT}=    RW.Core.Import User Variable    CONTEXT
    ...    type=string
    ...    description=Which Kubernetes context to operate within.
    ...    pattern=\w*
    ...    example=my-main-cluster
    ${OBJECT_NAME}=    RW.Core.Import User Variable
    ...    OBJECT_NAME
    ...    type=string
    ...    description=The name of the custom resource object. For example, a crunchdb databaase object named db1 would be "db1"
    ...    example=db1
    ${RESOURCE_LABELS}=    RW.Core.Import User Variable
    ...    RESOURCE_LABELS
    ...    type=string
    ...    description=Labels that can be used to identify all resources associated with the database.
    ...    example=postgres-operator.crunchydata.com/cluster=main-db
    ${WORKLOAD_NAME}=    RW.Core.Import User Variable
    ...    WORKLOAD_NAME
    ...    type=string
    ...    description=Which workload to run the postgres query from. This workload should have the psql binary in its image and be able to access the database workload within its network constraints. Accepts namespace and container details if desired. Also accepts labels, such as `-l postgres-operator.crunchydata.com/role=primary`. If using labels, make sure NAMESPACE is set.
    ...    pattern=\w*
    ...    example=deployment/myapp
    ${DATABASE_CONTAINER}=    RW.Core.Import User Variable
    ...    DATABASE_CONTAINER
    ...    type=string
    ...    description=The container to target when executing commands.
    ...    pattern=\w*
    ...    example=database
    ...    default=database
    ${NAMESPACE}=    RW.Core.Import User Variable
    ...    NAMESPACE
    ...    type=string
    ...    description=Which namespace the workload is in.
    ...    example=my-database-namespace
    ${QUERY}=    RW.Core.Import User Variable
    ...    QUERY
    ...    type=string
    ...    description=The postgres queries to run on the workload. These should return helpful details to triage your database.
    ...    pattern=\w*
    ...    default=SELECT d.datname AS database_name, pg_size_pretty(pg_database_size(d.datname)) AS database_size, (SELECT count(*) FROM pg_stat_activity WHERE datname = d.datname) AS active_connections FROM pg_database d;
    ...    example=SELECT (total_exec_time / 1000 / 60) as total, (total_exec_time/calls) as avg, query FROM pg_stat_statements ORDER BY 1 DESC LIMIT 100;
    ${HOSTNAME}=    RW.Core.Import User Variable
    ...    HOSTNAME
    ...    type=string
    ...    description=The hostname specified in the psql connection string. Use localhost, or leave blank, if the execution workload is also hosting the database.
    ...    pattern=\w*
    ...    example=localhost
    ...    default=
    ${KUBERNETES_DISTRIBUTION_BINARY}=    RW.Core.Import User Variable    KUBERNETES_DISTRIBUTION_BINARY
    ...    type=string
    ...    description=Which binary to use for Kubernetes CLI commands.
    ...    enum=[kubectl,oc]
    ...    example=kubectl
    ...    default=kubectl
    ${DATABASE_LAG_THRESHOLD}=    RW.Core.Import User Variable
    ...    DATABASE_LAG_THRESHOLD
    ...    type=string
    ...    description=The acceptable Lag (in MB) as reported by patronictl before raising an issue
    ...    pattern=\w*
    ...    example=100
    ...    default=100
    ${OBJECT_API_VERSION}=    RW.Core.Import User Variable
    ...    OBJECT_API_VERSION
    ...    type=string
    ...    description=The api version of the Kubernetes object. Used to determine the type of checks to perform.
    ...    pattern=\w*
    ...    example=acid.zalan.do/v1
    ...    default=
    ${OBJECT_KIND}=    RW.Core.Import User Variable
    ...    OBJECT_KIND
    ...    type=string
    ...    description=The fully qualified custom resource of the Kubernetes object.
    ...    pattern=\w*
    ...    example=postgresql.acid.zalan.do
    ...    default=
    ${BACKUP_MAX_AGE}=    RW.Core.Import User Variable
    ...    BACKUP_MAX_AGE
    ...    type=string
    ...    description=The maximum age (in hours) of the last backup before an issue is generated.
    ...    pattern=\w*
    ...    example=26
    ...    default=26
    ${CONNECTION_UTILIZATION_THRESHOLD}=    RW.Core.Import User Variable
    ...    CONNECTION_UTILIZATION_THRESHOLD
    ...    type=string
    ...    description=The percentage threshold (0-100) of max_connections usage before raising a warning. Critical alerts are raised at threshold + 10%.
    ...    pattern=\d+
    ...    example=80
    ...    default=80
    ${STORAGE_WARNING_THRESHOLD}=    RW.Core.Import User Variable
    ...    STORAGE_WARNING_THRESHOLD
    ...    type=string
    ...    description=The percentage threshold (0-100) of filesystem storage usage before raising a warning.
    ...    pattern=\d+
    ...    example=80
    ...    default=80
    ${STORAGE_CRITICAL_THRESHOLD}=    RW.Core.Import User Variable
    ...    STORAGE_CRITICAL_THRESHOLD
    ...    type=string
    ...    description=The percentage threshold (0-100) of filesystem storage usage before raising a critical alert.
    ...    pattern=\d+
    ...    example=90
    ...    default=90
    Set Suite Variable    ${kubeconfig}    ${kubeconfig}
    Set Suite Variable    ${KUBERNETES_DISTRIBUTION_BINARY}    ${KUBERNETES_DISTRIBUTION_BINARY}
    Set Suite Variable    ${CONTEXT}    ${CONTEXT}
    Set Suite Variable    ${NAMESPACE}    ${NAMESPACE}
    Set Suite Variable    ${RESOURCE_LABELS}    ${RESOURCE_LABELS}
    Set Suite Variable    ${WORKLOAD_NAME}    ${WORKLOAD_NAME}
    Set Suite Variable    ${DATABASE_CONTAINER}    ${DATABASE_CONTAINER}
    Set Suite Variable    ${QUERY}    ${QUERY}
    Set Suite Variable    ${DATABASE_LAG_THRESHOLD}    ${DATABASE_LAG_THRESHOLD}
    Set Suite Variable    ${OBJECT_API_VERSION}    ${OBJECT_API_VERSION}
    Set Suite Variable    ${OBJECT_KIND}    ${OBJECT_KIND}
    Set Suite Variable    ${OBJECT_NAME}    ${OBJECT_NAME}
    Set Suite Variable    ${BACKUP_MAX_AGE}    ${BACKUP_MAX_AGE}
    Set Suite Variable    ${CONNECTION_UTILIZATION_THRESHOLD}    ${CONNECTION_UTILIZATION_THRESHOLD}
    Set Suite Variable    ${STORAGE_WARNING_THRESHOLD}    ${STORAGE_WARNING_THRESHOLD}
    Set Suite Variable    ${STORAGE_CRITICAL_THRESHOLD}    ${STORAGE_CRITICAL_THRESHOLD}
    Set Suite Variable
    ...    ${env}
    ...    {"KUBECONFIG":"./${kubeconfig.key}", "NAMESPACE": "${NAMESPACE}", "CONTEXT": "${CONTEXT}", "RESOURCE_LABELS": "${RESOURCE_LABELS}", "OBJECT_NAME":"${OBJECT_NAME}", "OBJECT_API_VERSION": "${OBJECT_API_VERSION}", "KUBERNETES_DISTRIBUTION_BINARY":"${KUBERNETES_DISTRIBUTION_BINARY}", "DATABASE_CONTAINER": "${DATABASE_CONTAINER}", "QUERY":"${QUERY}", "BACKUP_MAX_AGE": "${BACKUP_MAX_AGE}", "CONNECTION_UTILIZATION_THRESHOLD": "${CONNECTION_UTILIZATION_THRESHOLD}", "STORAGE_WARNING_THRESHOLD": "${STORAGE_WARNING_THRESHOLD}", "STORAGE_CRITICAL_THRESHOLD": "${STORAGE_CRITICAL_THRESHOLD}"}

    # Verify cluster connectivity
    RW.K8sHelper.Verify Cluster Connectivity
    ...    binary=${KUBERNETES_DISTRIBUTION_BINARY}
    ...    context=${CONTEXT}
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    IF    "${HOSTNAME}" != ""
        ${HOSTNAME}=    Set Variable    -h ${HOSTNAME}
    END
    Set Suite Variable    ${HOSTNAME}    ${HOSTNAME}

