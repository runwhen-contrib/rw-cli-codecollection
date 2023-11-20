*** Settings ***
Documentation       Check the health of pods deployed by cert-manager.
Metadata            Author    jon-funk
Metadata            Display Name    Kubernetes CertManager Healthcheck
Metadata            Supports    Kubernetes,AKS,EKS,GKE,OpenShift

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             OperatingSystem

Suite Setup         Suite Initialization


*** Tasks ***
Get Health Score of CertManager Workloads
    [Documentation]    Returns a score of 1 when all cert-manager pods are healthy, or 0 otherwise.
    [Tags]    pods    containers    running    status    count    health    certmanager    cert
    # count expired certs
    ${expired_certs}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get --context=${CONTEXT} --all-namespaces certificates -ojson | jq '[.items[] | select(.status.notAfter != null) | {notAfter: .status.notAfter} | .notAfter |= (gsub("[-:TZ]"; "") | strptime("%Y%m%d%H%M%S") | mktime) | select(.notAfter < now)] | length'
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ${ec_count}=    Set Variable    ${expired_certs.stdout}
    ${ec_health_score}=    Set Variable    1
    IF    isinstance($ec_count, int) and $ec_count > 0
        ${ec_health_score}=    Evaluate    0.5 / ${ec_count}
    ELSE
        ${ec_health_score}=    Set Variable    0.5
    END
    # check certmanager workloads healthy
    ${cm_pods}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get pods --context=${CONTEXT} -n ${NAMESPACE} -ojson
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ${not_ready_count}=    RW.CLI.Parse Cli Json Output
    ...    rsp=${cm_pods}
    ...    extract_path_to_var__cm_stats=items[].{name:metadata.name, containers_ready:status.containerStatuses[].ready, containers_started:status.containerStatuses[].started}
    ...    from_var_with_path__cm_stats__to__not_ready_containers=length([].containers_ready[?@ == `false`][])
    ...    assign_stdout_from_var=not_ready_containers
    ${not_started_count}=    RW.CLI.Parse Cli Json Output
    ...    rsp=${cm_pods}
    ...    extract_path_to_var__cm_stats=items[].{name:metadata.name, containers_ready:status.containerStatuses[].ready, containers_started:status.containerStatuses[].started}
    ...    from_var_with_path__cm_stats__to__not_started_containers=length([].containers_started[?@ == `false`][])
    ...    assign_stdout_from_var=not_started_containers
    ${not_ready_count}=    Convert to Number    ${not_ready_count.stdout}
    ${not_started_count}=    Convert to Number    ${not_started_count.stdout}
    ${cm_health_score}=    Evaluate    0.5 if ${not_ready_count} == 0 and ${not_started_count} == 0 else 0
    ${metric}=    Evaluate    ${cm_health_score} + ${ec_health_score}
    RW.Core.Push Metric    ${metric}


*** Keywords ***
Suite Initialization
    ${kubeconfig}=    RW.Core.Import Secret
    ...    kubeconfig
    ...    type=string
    ...    description=The kubernetes kubeconfig yaml containing connection configuration used to connect to cluster(s).
    ...    pattern=\w*
    ...    example=For examples, start here https://kubernetes.io/docs/concepts/configuration/organize-cluster-access-kubeconfig/
    ${kubectl}=    RW.Core.Import Service    kubectl
    ...    description=The location service used to interpret shell commands.
    ...    default=kubectl-service.shared
    ...    example=kubectl-service.shared
    ${NAMESPACE}=    RW.Core.Import User Variable
    ...    NAMESPACE
    ...    type=string
    ...    description=The name of the Kubernetes namespace to scope actions and searching to. Supports csv list of namespaces.
    ...    pattern=\w*
    ...    default=cert-manager
    ...    example=cert-manager
    ${CONTEXT}=    RW.Core.Import User Variable    CONTEXT
    ...    type=string
    ...    description=Which Kubernetes context to operate within.
    ...    pattern=\w*
    ...    example=my-main-cluster

    ${DISTRIBUTION}=    RW.Core.Import User Variable    DISTRIBUTION
    ...    type=string
    ...    description=Which distribution of Kubernetes to use for operations, such as: Kubernetes, OpenShift, etc.
    ...    pattern=\w*
    ...    enum=[Kubernetes,GKE,OpenShift]
    ...    example=Kubernetes
    ...    default=Kubernetes

    ${KUBERNETES_DISTRIBUTION_BINARY}=    RW.Core.Import User Variable    KUBERNETES_DISTRIBUTION_BINARY
    ...    type=string
    ...    description=Which binary to use for Kubernetes CLI commands.
    ...    enum=[kubectl,oc]
    ...    example=kubectl
    ...    default=kubectl
    Set Suite Variable    ${KUBERNETES_DISTRIBUTION_BINARY}    ${KUBERNETES_DISTRIBUTION_BINARY}
    Set Suite Variable    ${kubeconfig}    ${kubeconfig}
    Set Suite Variable    ${kubectl}    ${kubectl}
    Set Suite Variable    ${CONTEXT}    ${CONTEXT}
    Set Suite Variable    ${NAMESPACE}    ${NAMESPACE}
    Set Suite Variable    ${env}    {"KUBECONFIG":"./${kubeconfig.key}"}
