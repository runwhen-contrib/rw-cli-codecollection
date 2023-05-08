*** Settings ***
Documentation       Runs multiple Kubernetes and psql commands to report on the health of a postgres cluster. 
Metadata            Author    Shea Stewart
Metadata            Display Name    Kubernetes Postgres Triage
Metadata            Supports    AKS, EKS, GKE, Kubernetes, Patroni, Postgres
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             String

Suite Setup         Suite Initialization



*** Tasks ***
Get Standard Postgres Resource Information
    [Documentation]    Runs a simple fetch all for the resources in the given workspace under the configured labels.
    [Tags]    Postgres    Resources    Workloads    Standard    Information
    ${results}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get all -l ${RESOURCE_LABELS} -n ${NAMESPACE} --context ${CONTEXT}
    ...    target_service=${kubectl}
    ...    env=${env}
    ...    secret_file__kubeconfig=${KUBECONFIG}
    ...    render_in_commandlist=true
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    ${results.stdout}
    RW.Core.Add Pre To Report    Commands Used:\n${history}

Describe Postgres Custom Resources
    [Documentation]    Runs a ftech all for the CRD types in the cluster and uses the type list after filtering it to fetch
    ...                a list of live runnig CRD workloads of those types and describe them.
    [Tags]    Postgres    Resources    Workloads    Customer Resource Definitions    CRD    Information
    ${crd_list}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get crd -n ${NAMESPACE} --context ${CONTEXT} -o=jsonpath='{.items[*].metadata.name}'
    ...    target_service=${kubectl}
    ...    env=${env}
    ...    secret_file__kubeconfig=${KUBECONFIG}
    ...    render_in_commandlist=true
    ${crd_list}=    Split String    ${crd_list.stdout}
    ${crd_names_to_keep}=    Split String    ${CRD_FILTER}    seperator=,
    ${crd_list}=    Evaluate    [crd_name for crd_name in ${crd_list} if crd_name in ${crd_names_to_keep}]
    ${crd_descriptions}=    Set Variable    No Custom Resources found!
    IF    len(${crd_list}) > 0
        ${crd_workloads}=    RW.CLI.Run Cli
        ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get {item} -n ${NAMESPACE} --context ${CONTEXT} -o=name
        ...    target_service=${kubectl}
        ...    env=${env}
        ...    loop_with_items=${crd_list}
        ...    secret_file__kubeconfig=${KUBECONFIG}
        ${crd_workloads}=    Split String    ${crd_workloads.stdout}
        ${crd_descriptions}=    RW.CLI.Run Cli
        ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} describe {item} -n ${NAMESPACE} --context ${CONTEXT}
        ...    target_service=${kubectl}
        ...    env=${env}
        ...    loop_with_items=${crd_workloads}
        ...    secret_file__kubeconfig=${KUBECONFIG}
        ${crd_descriptions}=    Set Variable    ${crd_descriptions.stdout}
    END
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    ${crd_descriptions}
    RW.Core.Add Pre To Report    Commands Used:\n${history} 

Get Postgres Pod Logs & Events
    [Documentation]    Queries Postgres-related pods for their recent logs and checks for any warning-type events.
    [Tags]    Postgres    Events    Warnings    Labels    Logs    Errors    Pods
    ${labeled_pods}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get pods -l ${RESOURCE_LABELS} -n ${NAMESPACE} --context ${CONTEXT} -o=name --field-selector=status.phase=Running
    ...    target_service=${kubectl}
    ...    env=${env}
    ...    secret_file__kubeconfig=${KUBECONFIG}
    ...    render_in_commandlist=true
    ${labeled_pod_names}=    Split String    ${labeled_pods.stdout}
    ${found_pod_logs}=    Set Variable    No logs found!
    ${found_pod_events}=    Set Variable    No events found!
    IF    len(${labeled_pod_names}) > 0
        ${temp_logs}=    RW.CLI.Run Cli
        ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} logs {item} -n ${NAMESPACE} --context ${CONTEXT} --tail=100
        ...    target_service=${kubectl}
        ...    env=${env}
        ...    secret_file__kubeconfig=${KUBECONFIG}
        ...    loop_with_items=${labeled_pod_names}

        ${involved_pod_names}=    Evaluate    [full_name.split("/")[-1] for full_name in ${labeled_pod_names}]
        ${temp_events}=    RW.CLI.Run Cli
        ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get events -n ${NAMESPACE} --context ${CONTEXT} --field-selector involvedObject.name={item}
        ...    target_service=${kubectl}
        ...    env=${env}
        ...    secret_file__kubeconfig=${KUBECONFIG}
        ...    loop_with_items=${involved_pod_names}

        ${found_pod_logs}=    Evaluate    """${temp_logs.stdout}""" if """${temp_logs.stdout}""" else "${found_pod_logs}"
        ${found_pod_events}=    Evaluate    """${temp_events.stdout}""" if """${temp_events.stdout}""" else "${found_pod_events}"
    END
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Log Results:\n${found_pod_logs}
    RW.Core.Add Pre To Report    Event Results:\n${found_pod_events}
    RW.Core.Add Pre To Report    Commands Used:\n${history}

Get Postgres Pod Resource Utilization
    [Documentation]    Performs and a top command on list of labeled postgres-related workloads to check pod resources.
    [Tags]    Top    Resources    Utilization    Pods    Workloads    CPU    Memory    Allocation    Postgres
    ${labeled_pods}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get pods -l ${RESOURCE_LABELS} -n ${NAMESPACE} --context ${CONTEXT} -o=name --field-selector=status.phase=Running
    ...    target_service=${kubectl}
    ...    env=${env}
    ...    secret_file__kubeconfig=${KUBECONFIG}
    ...    render_in_commandlist=true
    ${labeled_pods}=    Split String    ${labeled_pods.stdout}
    ${labeled_pods}=    Evaluate    [full_name.split("/")[-1] for full_name in ${labeled_pods}]
    ${resource_util_info}=    Set Variable    No resource utilization information could be found!
    IF    len(${labeled_pods}) > 0
        ${temp_top}=    RW.CLI.Run Cli
        ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} top pod {item} -n ${NAMESPACE} --context ${CONTEXT} --containers
        ...    target_service=${kubectl}
        ...    env=${env}
        ...    secret_file__kubeconfig=${KUBECONFIG}
        ...    loop_with_items=${labeled_pods}
        ${resource_util_info}=    Set Variable    ${temp_top.stdout}
    END
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Pod Resources:\n${resource_util_info}
    RW.Core.Add Pre To Report    Commands Used:\n${history}

Get Running Postgres Configuration
    [Documentation]    Fetches the postgres instance's configuration information.
    [Tags]    Config    Postgres    File    Show    Path    Setup    Configuration
    ${config_query}=    Set Variable    SHOW config_file
    ${full_cmd}=    RW.CLI.Escape Str For Exec    echo "${config_query}" > /tmp/rw-tmp-queries.sql && ${PSQL_RUN_PASSTHROUGH}
    ${config_rsp}=    RW.CLI.Run Cli
    ...    cmd=${full_cmd}
    ...    env=${env}
    ...    run_in_workload_with_labels=${RESOURCE_LABELS}
    ...    optional_namespace=${NAMESPACE}
    ...    optional_context=${CONTEXT}
    ...    secret_file__kubeconfig=${KUBECONFIG}
    ...    secret__psql_password=${psql_password}
    ...    secret__psql_username=${psql_username}
    ...    secret__psql_database=${psql_database}
    ${active_db_config_location}=     Split String    ${config_rsp.stdout}
    ${active_db_config_contents}=    RW.CLI.Run Cli
    ...    cmd=cat ${active_db_config_location[0]}
    ...    env=${env}
    ...    run_in_workload_with_labels=${RESOURCE_LABELS}
    ...    optional_namespace=${NAMESPACE}
    ...    optional_context=${CONTEXT}
    ...    secret_file__kubeconfig=${KUBECONFIG}
    ...    secret__psql_password=${psql_password}
    ...    secret__psql_username=${psql_username}
    ...    secret__psql_database=${psql_database}
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    File Path:\n${active_db_config_location[0]}\n--------\nFile Contents:\n${active_db_config_contents.stdout}\n--------
    RW.Core.Add Pre To Report    Commands Used:\n${history}

Get Patroni Output
    [Documentation]    Attempts to run the patronictl CLI within the workload if it's available to check the current state of a patroni cluster, if applicable.
    [Tags]    Patroni    patronictl    List    Cluster    Health    Check    state    Postgres
    ${rsp}=    RW.CLI.Run Cli
    ...    cmd=patronictl list
    ...    env=${env}
    ...    run_in_workload_with_labels=${RESOURCE_LABELS}
    ...    optional_namespace=${NAMESPACE}
    ...    optional_context=${CONTEXT}
    ...    secret_file__kubeconfig=${KUBECONFIG}
    ...    secret__psql_password=${psql_password}
    ...    secret__psql_username=${psql_username}
    ...    secret__psql_database=${psql_database}
    ...    render_in_commandlist=true
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    ${rsp.stdout}

Run DB Queries
    [Documentation]    Runs a suite of configurable queries to check for index issues, slow-queries, etc and create a report.
    [Tags]    Slow Queries    Index    Health    Triage    Postgres    Patroni    Tables
    ${escaped_query}=    RW.CLI.Escape Str For Exec    \\t off \\\\\\\\\\ \\a \\\\\\\\\\ \\timing on \\\\\\\\\\ ${QUERY}
    ${full_cmd}=    RW.CLI.Escape Str For Exec    echo "${escaped_query}" > /tmp/rw-tmp-queries.sql && ${PSQL_RUN_PASSTHROUGH}
    ${rsp}=    RW.CLI.Run Cli
    ...    cmd=${full_cmd}
    ...    env=${env}
    ...    run_in_workload_with_labels=${RESOURCE_LABELS}
    ...    optional_namespace=${NAMESPACE}
    ...    optional_context=${CONTEXT}
    ...    secret_file__kubeconfig=${KUBECONFIG}
    ...    secret__psql_password=${psql_password}
    ...    secret__psql_username=${psql_username}
    ...    secret__psql_database=${psql_database}
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    ${rsp.stdout}


*** Keywords ***
Suite Initialization
    ${kubeconfig}=    RW.Core.Import Secret
    ...    kubeconfig
    ...    type=string
    ...    description=The kubernetes kubeconfig yaml containing connection configuration used to connect to cluster(s).
    ...    pattern=\w*
    ...    example=For examples, start here https://kubernetes.io/docs/concepts/configuration/organize-cluster-access-kubeconfig/
    ${psql_password}=    RW.Core.Import Secret    psql_password
    ...    type=string
    ...    description=The password used when querying the postgres database.
    ...    pattern=\w*
    ...    example=mysupersecretpassword
    ${psql_database}=    RW.Core.Import Secret    psql_database
    ...    type=string
    ...    description=The database name used to determine what database is being queried.
    ...    pattern=\w*
    ...    example=mydb
    ...    default=postgres
    ${psql_username}=    RW.Core.Import Secret    psql_username
    ...    type=string
    ...    description=The username used when querying the postgres database.
    ...    pattern=\w*
    ...    example=myuser
    ${kubectl}=    RW.Core.Import Service    kubectl
    ...    description=The location service used to interpret shell commands.
    ...    default=kubectl-service.shared
    ...    example=kubectl-service.shared
    ${CONTEXT}=    RW.Core.Import User Variable    CONTEXT
    ...    type=string
    ...    description=Which Kubernetes context to operate within.
    ...    pattern=\w*
    ...    example=my-main-cluster
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
    ...    default=SELECT (total_exec_time / 1000 / 60) as total, (total_exec_time/calls) as avg, query FROM pg_stat_statements ORDER BY 1 DESC LIMIT 100;SELECT pg_stat_activity.pid, pg_locks.relation::regclass, pg_locks.mode, pg_locks.granted FROM pg_stat_activity, pg_locks WHERE pg_stat_activity.pid = pg_locks.pid; SELECT pg_database.datname, pg_size_pretty(pg_database_size(pg_database.datname)) AS size FROM pg_database; SELECT query, count(*) as total_executions, avg(total_exec_time) as avg_execution_time FROM pg_stat_statements GROUP BY query ORDER BY total_executions DESC; SELECT schemaname, relname, last_autovacuum, last_autoanalyze FROM pg_stat_user_tables WHERE last_autovacuum IS NOT NULL OR last_autoanalyze IS NOT NULL;
    ...    example=SELECT (total_exec_time / 1000 / 60) as total, (total_exec_time/calls) as avg, query FROM pg_stat_statements ORDER BY 1 DESC LIMIT 100;
    ${HOSTNAME}=    RW.Core.Import User Variable
    ...    HOSTNAME
    ...    type=string
    ...    description=The hostname specified in the psql connection string. Use localhost, or leave blank, if the execution workload is also hosting the database.
    ...    pattern=\w*
    ...    example=localhost
    ...    default=
    ${CRD_FILTER}=    RW.Core.Import User Variable
    ...    CRD_FILTER
    ...    type=string
    ...    description=A csv of CRD names to use for triaging and collecting information.
    ...    pattern=\w*
    ...    example=localhost
    ${KUBERNETES_DISTRIBUTION_BINARY}=    RW.Core.Import User Variable    KUBERNETES_DISTRIBUTION_BINARY
    ...    type=string
    ...    description=Which binary to use for Kubernetes CLI commands.
    ...    enum=[kubectl,oc]
    ...    example=kubectl
    ...    default=kubectl

    Set Suite Variable    ${kubeconfig}    ${kubeconfig}
    Set Suite Variable    ${kubectl}    ${kubectl}
    Set Suite Variable    ${KUBERNETES_DISTRIBUTION_BINARY}    ${KUBERNETES_DISTRIBUTION_BINARY}
    Set Suite Variable    ${CONTEXT}    ${CONTEXT}
    Set Suite Variable    ${NAMESPACE}    ${NAMESPACE}
    Set Suite Variable    ${RESOURCE_LABELS}    ${RESOURCE_LABELS}
    Set Suite Variable    ${WORKLOAD_NAME}    ${WORKLOAD_NAME}
    Set Suite Variable    ${QUERY}    ${QUERY}
    Set Suite Variable    ${CRD_FILTER}    ${CRD_FILTER}
    Set Suite Variable    ${psql_username}    ${psql_username}
    Set Suite Variable    ${psql_database}    ${psql_database}
    Set Suite Variable    ${psql_password}    ${psql_password}
    Set Suite Variable    ${env}    {"KUBECONFIG":"./${kubeconfig.key}"}
    IF    "${HOSTNAME}" != ""
        ${HOSTNAME}=    Set Variable    -h ${HOSTNAME}        
    END
    Set Suite Variable    ${HOSTNAME}    ${HOSTNAME}
    Set Suite Variable    ${PSQL_RUN_PASSTHROUGH}        PGPASSWORD\="$${psql_password.key}" psql -qAt -U $${psql_username.key} -d $${psql_database.key} ${HOSTNAME} -e -f '/tmp/rw-tmp-queries.sql'

