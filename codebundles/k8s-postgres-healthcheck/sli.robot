*** Settings ***
Documentation       Runs multiple Kubernetes and psql commands to report on the health of a postgres cluster. Produces a value between 0 (completely failing thet test) and 1 (fully passing the test). Looks for container restarts, events, and pods not ready.
Metadata            Author    stewartshea
Metadata            Display Name    Kubernetes Postgres Healthcheck
Metadata            Supports    AKS,EKS,GKE,Kubernetes,Patroni,Postgres,Crunchy

Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             String
Library             Collections

Suite Setup         Suite Initialization


*** Tasks ***
Fetch Patroni Database Lag
    [Documentation]    Identifies the lag using patronictl and raises issues if necessary.
    [Tags]    patroni    patronictl    list    cluster    health    check    state    postgres
    ${database_lag_score}=    Set Variable    1
    ${patroni_output}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} exec $(${KUBERNETES_DISTRIBUTION_BINARY} get pods ${WORKLOAD_NAME} -n ${NAMESPACE} --context ${CONTEXT} -o jsonpath='{.items[0].metadata.name}') -n ${NAMESPACE} --context ${CONTEXT} -c ${DATABASE_CONTAINER} -- patronictl list -f json
    ...    env=${env}
    ...    secret_file__kubeconfig=${KUBECONFIG}
    ${patroni_members}=    Evaluate    json.loads(r'''${patroni_output.stdout}''')    json
    IF    len(@{patroni_members}) > 0
        FOR    ${item}    IN    @{patroni_members}
            IF    "Lag in MB" not in ${item}    CONTINUE
            ${lag_in_mb}=    Get From Dictionary    ${item}    Lag in MB
            IF    ${lag_in_mb} > ${DATABASE_LAG_THRESHOLD}
                Log
                ...    Database member `${item["Member"]}` in Cluster `${item["Cluster"]}` has of ${lag_in_mb} MB in `${NAMESPACE}`. Threshold is ${DATABASE_LAG_THRESHOLD} MB.
                ${database_lag_score}=    Set Variable    0
                BREAK
            END
        END
    END
    Set Global Variable    ${database_lag_score}

Generate Namspace Score
    ${postgres_health_score}=    Evaluate    (${database_lag_score} ) / 1
    ${health_score}=    Convert to Number    ${postgres_health_score}    2
    RW.Core.Push Metric    ${postgres_health_score}


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
    Set Suite Variable    ${kubeconfig}    ${kubeconfig}
    Set Suite Variable    ${KUBERNETES_DISTRIBUTION_BINARY}    ${KUBERNETES_DISTRIBUTION_BINARY}
    Set Suite Variable    ${CONTEXT}    ${CONTEXT}
    Set Suite Variable    ${NAMESPACE}    ${NAMESPACE}
    Set Suite Variable    ${RESOURCE_LABELS}    ${RESOURCE_LABELS}
    Set Suite Variable    ${WORKLOAD_NAME}    ${WORKLOAD_NAME}
    Set Suite Variable    ${DATABASE_CONTAINER}    ${DATABASE_CONTAINER}
    Set Suite Variable    ${DATABASE_LAG_THRESHOLD}    ${DATABASE_LAG_THRESHOLD}
    Set Suite Variable    ${env}    {"KUBECONFIG":"./${kubeconfig.key}"}
    IF    "${HOSTNAME}" != ""
        ${HOSTNAME}=    Set Variable    -h ${HOSTNAME}
    END
    Set Suite Variable    ${HOSTNAME}    ${HOSTNAME}
