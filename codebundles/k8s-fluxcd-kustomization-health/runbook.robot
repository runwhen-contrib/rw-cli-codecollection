*** Settings ***
Documentation       This codebundle runs a series of tasks to identify potential Kustomization issues related to Flux managed Kustomization objects. 
Metadata            Author    stewartshea
Metadata            Display Name    Kubernetes FluxCD Kustomization TaskSet
Metadata            Supports    Kubernetes,AKS,EKS,GKE,OpenShift,FluxCD
Library             RW.Core
Library             RW.CLI
Library             RW.platform

Suite Setup         Suite Initialization


*** Tasks ***
List all available Kustomization objects in Namespace `${NAMESPACE}`    
    [Documentation]    List all FluxCD kustomization objects found in ${NAMESPACE}
    [Tags]        FluxCD     Kustomization     Available    List    ${NAMESPACE}
    ${kustomizations}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get ${RESOURCE_NAME} -n ${NAMESPACE} --context ${CONTEXT}
    ...    env=${env}
    ...    secret_file__kubeconfig=${KUBECONFIG}
    ...    show_in_rwl_cheatsheet=true
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Kustomizations available: \n ${kustomizations.stdout}
    RW.Core.Add Pre To Report    Commands Used:\n${history}

Get details for unready Kustomizations in Namespace `${NAMESPACE}`  
    [Documentation]    List all Kustomizations that are not found in a ready state in namespace ${NAMESPACE}  
    [Tags]        FluxCD     Kustomization    Versions    ${NAMESPACE}
    ${kustomizations_not_ready}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get ${RESOURCE_NAME} -n ${NAMESPACE} --context ${CONTEXT} -o json | jq -r '.items[] | select (.status.conditions[] | select(.type == "Ready" and .status == "False")) | "---\\nKustomization Name: \\(.metadata.name)\\n\\nReady Status: \\(.status.conditions[] | select(.type == "Ready") | "\\n ready: \\(.status)\\n message: \\(.message)\\n reason: \\(.reason)\\n last_transition_time: \\(.lastTransitionTime)")\\n\\nReconcile Status:\\(.status.conditions[] | select(.type == "Reconciling") |"\\n reconciling: \\(.status)\\n message: \\(.message)")\\n---\\n"'
    ...    env=${env}
    ...    secret_file__kubeconfig=${KUBECONFIG}
    ...    show_in_rwl_cheatsheet=true
    RW.CLI.Parse Cli Output By Line
    ...    rsp=${kustomizations_not_ready}
    ...    set_severity_level=2
    ...    set_issue_expected=Kustomizations should be synced and ready.   
    ...    set_issue_actual=We found the following kustomization objects in a pending state: $_stdout
    ...    set_issue_title=Unready Kustomizations Found In Namespace ${NAMESPACE}
    ...    set_issue_details=Kustomizations pending with reasons:\n"$_stdout" in the namespace ${NAMESPACE}
    ...    _line__raise_issue_if_contains=-
    ${history}=    RW.CLI.Pop Shell History
    IF    """${kustomizations_not_ready.stdout}""" == ""
        ${kustomizations_not_ready}=    Set Variable    No Kustomizations Pending Found
    ELSE
        ${kustomizations_not_ready}=    Set Variable    ${kustomizations_not_ready.stdout}
    END
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Kustomizations with: \n ${kustomizations_not_ready}
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
    ${NAMESPACE}=    RW.Core.Import User Variable    NAMESPACE
    ...    type=string
    ...    description=The name of the Kubernetes namespace to scope actions and searching to. 
    ...    pattern=\w*
    ...    example=my-namespace
    ...    default=default
    ${RESOURCE_NAME}=    RW.Core.Import User Variable    RESOURCE_NAME
    ...    type=string
    ...    description=The short or long name of the Kubernetes kustomizations resource to search for. These might vary by Kustomize controller implementation, and are best to use full crd name. 
    ...    pattern=\w*
    ...    example=kustomizations.kustomize.toolkit.fluxcd.io
    ...    default=kustomizations
    ${CONTEXT}=    RW.Core.Import User Variable    CONTEXT
    ...    type=string
    ...    description=Which Kubernetes context to operate within.
    ...    pattern=\w*
    ...    default=default
    ...    example=my-main-cluster
    Set Suite Variable    ${KUBERNETES_DISTRIBUTION_BINARY}    ${KUBERNETES_DISTRIBUTION_BINARY}
    Set Suite Variable    ${kubeconfig}    ${kubeconfig}
    Set Suite Variable    ${RESOURCE_NAME}    ${RESOURCE_NAME}
    Set Suite Variable    ${NAMESPACE}    ${NAMESPACE}
    Set Suite Variable    ${env}    {"KUBECONFIG":"./${kubeconfig.key}"}
