*** Settings ***
Documentation       This codebundle runs a series of tasks to identify potential Kustomization issues related to Flux managed Kustomization objects. 
Metadata            Author    stewartshea
Metadata            Display Name    Kubernetes FluxCD Kustomization TaskSet
Metadata            Supports    Kubernetes,AKS,EKS,GKE,OpenShift,FluxCD
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             RW.NextSteps
Library             String

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
    ...    render_in_commandlist=true
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Kustomizations available: \n ${kustomizations.stdout}
    RW.Core.Add Pre To Report    Commands Used:\n${history}

Get details for unready Kustomizations in Namespace `${NAMESPACE}`  
    [Documentation]    List all Kustomizations that are not found in a ready state in namespace ${NAMESPACE}  
    [Tags]        FluxCD     Kustomization    Versions    ${NAMESPACE}
    ${kustomizations_not_ready}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get ${RESOURCE_NAME} -n ${NAMESPACE} --context ${CONTEXT} -o json | jq '[.items[] | select(.status.conditions[] | select(.type == "Ready" and .status == "False")) | {KustomizationName: .metadata.name, ReadyStatus: {ready: (.status.conditions[] | select(.type == "Ready").status), message: (.status.conditions[] | select(.type == "Ready").message), reason: (.status.conditions[] | select(.type == "Ready").reason), last_transition_time: (.status.conditions[] | select(.type == "Ready").lastTransitionTime)}, ReconcileStatus: {reconciling: (.status.conditions[] | select(.type == "Reconciling").status), message: (.status.conditions[] | select(.type == "Reconciling").message)}}]'
    ...    env=${env}
    ...    secret_file__kubeconfig=${KUBECONFIG}
    ...    show_in_rwl_cheatsheet=true
    ${kustomizations_not_ready_list}=    Evaluate    json.loads(r'''${kustomizations_not_ready.stdout}''')    json
    IF    len(@{kustomizations_not_ready_list}) > 0
        FOR    ${item}    IN    @{kustomizations_not_ready_list}               
            ${messages}=    Replace String    ${item["ReadyStatus"]["message"]}   "    ${EMPTY}
            ${item_next_steps}=    RW.CLI.Run Bash File
            ...    bash_file=workload_next_steps.sh
            ...    cmd_override=./workload_next_steps.sh "${messages}"
            ...    env=${env}
            ...    include_in_history=False
            RW.Core.Add Issue
            ...    severity=2
            ...    expected=Kustomizations should be synced and ready.   
            ...    actual=Objects are not ready.
            ...    title=GitOps Resources are Unhealthy in Namespace \`${NAMESPACE}\`
            ...    reproduce_hint=${kustomizations_not_ready.cmd}
            ...    details=Kustomization is not in a ready state ${item["KustomizationName"]} in Namespace ${NAMESPACE}\n${item}
            ...    next_steps=${item_next_steps.stdout}
        END
    END
    ${history}=    RW.CLI.Pop Shell History
    IF    """${kustomizations_not_ready.stdout}""" == ""
        ${kustomizations_not_ready}=    Set Variable    No Kustomizations Pending Found
    ELSE
        ${kustomizations_not_ready}=    Set Variable    ${kustomizations_not_ready.stdout}
    END
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
