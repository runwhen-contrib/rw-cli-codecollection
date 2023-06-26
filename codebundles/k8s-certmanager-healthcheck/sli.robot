*** Settings ***
Metadata          Author    jon-funk
Documentation     Check the health of pods deployed by cert-manager.
Metadata          Display Name    Kubernetes CertManager Healthcheck
Metadata          Supports    Kubernetes,AKS,EKS,GKE,OpenShift
Suite Setup       Suite Initialization
Library           BuiltIn
Library           RW.Core
Library           RW.CLI
Library           RW.platform
Library           OperatingSystem

*** Keywords ***
Suite Initialization
    ${kubeconfig}=    RW.Core.Import Secret    kubeconfig
    ...    type=string
    ...    description=The kubernetes kubeconfig yaml containing connection configuration used to connect to cluster(s).
    ...    pattern=\w*
    ...    example=For examples, start here https://kubernetes.io/docs/concepts/configuration/organize-cluster-access-kubeconfig/
    ${kubectl}=    RW.Core.Import Service    kubectl
    ...    description=The location service used to interpret shell commands.
    ...    default=kubectl-service.shared
    ...    example=kubectl-service.shared
    ${NAMESPACE}=    RW.Core.Import User Variable    NAMESPACE
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
    Set Suite Variable    ${kubeconfig}    ${kubeconfig}
    Set Suite Variable    ${kubectl}    ${kubectl}
    Set Suite Variable    ${CONTEXT}    ${CONTEXT}
    Set Suite Variable    ${NAMESPACE}    ${NAMESPACE}
    Set Suite Variable    ${env}    {"KUBECONFIG":"./${kubeconfig.key}"}

*** Tasks ***
Get Health Score of CertManager Workloads
    [Documentation]    Returns a score of 1 when all cert-manager pods are healthy, or 0 otherwise.
    [Tags]    Pods    Containers    Running    Status    Count    Health    CertManager    Cert
    ${cm_pods}=    RW.CLI.Run Cli
    ...    cmd=kubectl get pods --context=${CONTEXT} -n ${NAMESPACE} -ojson
    ...    target_service=${kubectl}
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
    ${not_ready_count}=      Convert to Number    ${not_ready_count.stdout}
    ${not_started_count}=      Convert to Number    ${not_started_count.stdout}
    ${metric}=    Evaluate    1 if ${not_ready_count} == 0 and ${not_started_count} == 0 else 0
    RW.Core.Push Metric    ${metric}