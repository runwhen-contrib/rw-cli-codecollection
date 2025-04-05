*** Settings ***
Documentation       This codebundle checks for unhealthy or suspended FluxCD Kustomization objects. 
Metadata            Author    stewartshea
Metadata            Display Name    Kubernetes FluxCD Kustomization Health
Metadata            Supports    Kubernetes,AKS,EKS,GKE,OpenShift,FluxCD
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             RW.NextSteps
Library             String

Suite Setup         Suite Initialization


*** Tasks ***
List Suspended FluxCD Kustomization objects in Namespace `${NAMESPACE}` in Cluster `${CONTEXT}`  
    [Documentation]    List Suspended FluxCD kustomization objects.
    [Tags]            access:read-only  FluxCD     Kustomization     Suspended    List
    ${suspended_kustomizations}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get ${RESOURCE_NAME} -n "${NAMESPACE}" --context "${CONTEXT}" -o json | jq --arg now "$(date -u +%s)" '[.items[] | select(.spec.suspend == true) | {KustomizationName: .metadata.name, SuspendedSince: (.status.conditions[] | select(.type=="Ready") | .lastTransitionTime), SuspendedDurationHours: (( ($now|tonumber) - ((.status.conditions[] | select(.type=="Ready") | .lastTransitionTime) | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime)) / 3600 * 100 | round / 100 )}]'
    ...    env=${env}
    ...    secret_file__kubeconfig=${KUBECONFIG}
    ...    show_in_rwl_cheatsheet=true
    ...    render_in_commandlist=true
    ${history}=    RW.CLI.Pop Shell History
    ${suspended_kustomization_score}=    Set Variable    0
    ${suspended_kustomization_list}=    Evaluate    json.loads(r'''${suspended_kustomizations.stdout}''')    json
    IF    len(@{suspended_kustomization_list}) > 0 
        ${suspended_kustomization_score}=    Set Variable    0
    END
    Set Global Variable    ${suspended_kustomization_score}



List Unready FluxCD Kustomizations in Namespace `${NAMESPACE}` in Cluster `${CONTEXT}` 
    [Documentation]    List all Kustomizations that are not found in a ready state in namespace.
    [Tags]        access:read-only  FluxCD     Kustomization    Versions    ${NAMESPACE}
    ${kustomizations_not_ready}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get ${RESOURCE_NAME} -n ${NAMESPACE} --context ${CONTEXT} -o json | jq '[.items[] | select(.status.conditions[] | select(.type == "Ready" and .status == "False")) | {KustomizationName: .metadata.name, ReadyStatus: {ready: (.status.conditions[] | select(.type == "Ready").status), message: (.status.conditions[] | select(.type == "Ready").message), reason: (.status.conditions[] | select(.type == "Ready").reason), last_transition_time: (.status.conditions[] | select(.type == "Ready").lastTransitionTime)}, ReconcileStatus: {reconciling: (.status.conditions[] | select(.type == "Reconciling").status), message: (.status.conditions[] | select(.type == "Reconciling").message)}}]'
    ...    env=${env}
    ...    secret_file__kubeconfig=${KUBECONFIG}
    ...    show_in_rwl_cheatsheet=true
    ${kustomizations_not_ready_list}=    Evaluate    json.loads(r'''${kustomizations_not_ready.stdout}''')    json
    ${unready_kustomization_score}=    Set Variable    0
    IF    len(@{kustomizations_not_ready_list}) > 0 
        ${unready_kustomization_score}=    Set Variable    0
    END
    Set Global Variable    ${unready_kustomization_score}

Generate FluxCD Kustomization Health Score for Namespace `${NAMESPACE}` in Cluster `${CONTEXT}`
    ${kustomization_health_score}=      Evaluate  (${unready_kustomization_score} + ${suspended_kustomization_score}) / 2
    ${health_score}=      Convert to Number    ${kustomization_health_score}  2
    RW.Core.Push Metric    ${health_score}

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
