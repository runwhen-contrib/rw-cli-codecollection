*** Settings ***
Documentation       Inspects the resources provisioned for a given set of pods, selected by their labels and raises issues if no resources were specified.
Metadata            Author    jon-funk
Metadata            Display Name    Kubernetes Pod Resources Scan
Metadata            Supports    Kubernetes,AKS,EKS,GKE,OpenShift

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             String
Library             OperatingSystem

Suite Setup         Suite Initialization


*** Tasks ***
Scan Labeled Pods and Show All Containers Without Resource Limit or Resource Requests Set
    [Documentation]    Scans a list of pods in a namespace using labels as a selector and checks if their resources are set.
    [Tags]
    ...    pods
    ...    resources
    ...    resource
    ...    allocation
    ...    cpu
    ...    memory
    ...    startup
    ...    initialization
    ...    prehook
    ...    liveness
    ...    readiness
    ${pods_without_limits}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get pods --context=${CONTEXT} -n ${NAMESPACE} ${LABELS} --field-selector=status.phase=Running -ojson | jq -r '[.items[] as $pod | ($pod.spec.containers // [][])[] | select(.resources.limits == null) | {pod: $pod.metadata.name, container_without_limits: .name}]'
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    target_service=${kubectl}
    ...    render_in_commandlist=true
    ${no_limits_count}=    RW.CLI.Parse Cli Json Output
    ...    rsp=${pods_without_limits}
    ...    extract_path_to_var__no_limits_count=length(@)
    ...    set_severity_level=4
    ...    no_limit_count__raise_issue_if_gt=0
    ...    set_issue_title=Pods With No Limits In Namespace ${NAMESPACE}
    ...    set_issue_details=Pods found without limits applied in namespace ${NAMESPACE}. \n $_stdout \n Review each manifest and edit configuration to set appropriate resource limits.
    ...    assign_stdout_from_var=no_limits_count
    ${pods_without_requests}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get pods --context=${CONTEXT} -n ${NAMESPACE} ${LABELS} --field-selector=status.phase=Running -ojson | jq -r '[.items[] as $pod | ($pod.spec.containers // [][])[] | select(.resources.requests == null) | {pod: $pod.metadata.name, container_without_requests: .name}]'
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    target_service=${kubectl}
    ...    render_in_commandlist=true
    ${no_requests_count}=    RW.CLI.Parse Cli Json Output
    ...    rsp=${pods_without_requests}
    ...    extract_path_to_var__no_requests_count=length(@)
    ...    set_issue_title=Found pod without resource requests specified in namespace ${NAMESPACE}.
    ...    set_severity_level=4
    ...    no_requests_count__raise_issue_if_gt=0
    ...    set_issue_details=Pods found without resource requests applied in namespace ${NAMESPACE}. \n $_stdout \n Review each manifest and edit configuration to set appropriate resource limits.
    ...    assign_stdout_from_var=no_requests_count
    ${history}=    RW.CLI.Pop Shell History
    ${no_requests_pod_count}=    Convert To Number    ${no_requests_count.stdout}
    ${no_limits_pod_count}=    Convert To Number    ${no_limits_count.stdout}
    ${container_count}=    Set Variable    ${no_requests_pod_count} + ${no_limits_pod_count}
    ${summary}=    Set Variable    No containers with unset resources found!
    IF    ${container_count} > 0
        ${summary}=    Set Variable
        ...    ${container_count} containers found without resources specified:\n${pods_without_limits.stdout}\n ${pods_without_requests.stdout}
    END
    RW.Core.Add Pre To Report    ${summary}
    RW.Core.Add Pre To Report    Commands Used:\n${history}

Get Labeled Container Top Info
    [Documentation]    Performs and a top command on list of labeled workloads to check pod resources.
    [Tags]    top    resources    utilization    pods    workloads    cpu    memory    allocation    labeled
    ${pods_top}=    RW.CLI.Run Cli
    ...    cmd=for pod in $(${KUBERNETES_DISTRIBUTION_BINARY} get pods ${LABELS} -n ${NAMESPACE} --context ${CONTEXT} -o custom-columns=":metadata.name" --field-selector=status.phase=Running); do ${KUBERNETES_DISTRIBUTION_BINARY} top pod $pod -n ${NAMESPACE} --context ${CONTEXT} --containers; done
    ...    target_service=${kubectl}
    ...    env=${env}
    ...    secret_file__kubeconfig=${KUBECONFIG}
    ...    render_in_commandlist=true
    ${resource_util_info}=    Set Variable    No resource utilization information could be found!
    IF    """${pods_top.stdout}""" != ""
        ${resource_util_info}=    Set Variable    ${pods_top.stdout}
    END
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Pod Resources:\n${resource_util_info}
    RW.Core.Add Pre To Report    Commands Used:\n${history}


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
    ...    example=my-namespace
    ${CONTEXT}=    RW.Core.Import User Variable    CONTEXT
    ...    type=string
    ...    description=Which Kubernetes context to operate within.
    ...    pattern=\w*
    ...    example=my-main-cluster
    ${LABELS}=    RW.Core.Import User Variable    LABELS
    ...    type=string
    ...    description=The metadata labels to use when selecting the objects to measure as running.
    ...    pattern=\w*
    ...    example=app=myapp
    ${KUBERNETES_DISTRIBUTION_BINARY}=    RW.Core.Import User Variable    KUBERNETES_DISTRIBUTION_BINARY
    ...    type=string
    ...    description=Which binary to use for Kubernetes CLI commands.
    ...    enum=[kubectl,oc]
    ...    example=kubectl
    ...    default=kubectl
    Set Suite Variable    ${kubeconfig}    ${kubeconfig}
    Set Suite Variable    ${kubectl}    ${kubectl}
    Set Suite Variable    ${CONTEXT}    ${CONTEXT}
    Set Suite Variable    ${NAMESPACE}    ${NAMESPACE}
    Set Suite Variable    ${KUBERNETES_DISTRIBUTION_BINARY}    ${KUBERNETES_DISTRIBUTION_BINARY}
    Set Suite Variable    ${env}    {"KUBECONFIG":"./${kubeconfig.key}"}
    IF    "${LABELS}" != ""
        ${LABELS}=    Set Variable    -l ${LABELS}
    END
    Set Suite Variable    ${LABELS}    ${LABELS}
