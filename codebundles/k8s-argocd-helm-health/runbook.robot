*** Settings ***
Documentation       This codebundle runs a series of tasks to identify potential helm release issues related to ArgoCD managed Helm objects.
Metadata            Author    nmadhok
Metadata            Display Name    Kubernetes ArgoCD HelmRelease TaskSet
Metadata            Supports    Kubernetes,AKS,EKS,GKE,OpenShift,ArgoCD

Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             RW.K8sHelper

Suite Setup         Suite Initialization


*** Tasks ***
Fetch all available ArgoCD Helm releases in namespace `${NAMESPACE}`
    [Documentation]    List all ArgoCD helm releases that are visible to the kubeconfig.
    [Tags]    argocd    helmrelease    available    list    health    data:config
    ${helmreleases}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get ${RESOURCE_NAME} -n ${NAMESPACE} --context ${CONTEXT} -o=json | jq -r '.items[] | select(.spec.source.helm != null) | "\\nName:\\t\\t\\t" + .metadata.name + "\\nSync Status:\\t\\t" + .status.sync.status + "\\nHealth Status:\\t\\t" + .status.health.status'
    ...    env=${env}
    ...    secret_file__kubeconfig=${KUBECONFIG}
    ...    show_in_rwl_cheatsheet=true
    ...    render_in_commandlist=true
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    \n\nArgoCD Helm releases available: \n${helmreleases.stdout}
    RW.Core.Add Pre To Report    Commands Used:\n${history}

Fetch Installed ArgoCD Helm release versions in namespace `${NAMESPACE}`
    [Documentation]    Fetch Installed ArgoCD Helm release Versions.
    [Tags]    argocd    helmrelease    version    state    data:config
    ${argocd_helm_status}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get ${RESOURCE_NAME} -n ${NAMESPACE} --context ${CONTEXT} -o=json | jq -r '.items[] | select(.spec.source.helm != null) | "\\nName:\\t\\t\\t" + .metadata.name + "\\nTarget Revision:\\t" + .spec.source.targetRevision + "\\nAttempted Revision:\\t" + .status.sync.revision + "\\nSync Status:\\t\\t" + .status.sync.status + "\\nOperational State:\\t" + .status.operationState.message'
    ...    env=${env}
    ...    secret_file__kubeconfig=${KUBECONFIG}
    ...    show_in_rwl_cheatsheet=true
    ...    render_in_commandlist=true
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    \n\nArgoCD Helm release Status: \n${argocd_helm_status.stdout}
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

    ${NAMESPACE}=    RW.Core.Import User Variable
    ...    NAMESPACE
    ...    type=string
    ...    description=The name of the Kubernetes namespace to scope actions and searching to. Accepts a single namespace in the format `-n namespace-name` or `--all-namespaces`.
    ...    pattern=\w*

    ${RESOURCE_NAME}=    RW.Core.Import User Variable
    ...    RESOURCE_NAME
    ...    type=string
    ...    description=The short or long name of the Kubernetes helmrelease resource to search for. These might vary by helm controller implementation, and are best to use full crd name.
    ...    pattern=\w*
    ...    example=applications.argoproj.io
    ...    default=applications.argoproj.io

    ${CONTEXT}=    RW.Core.Import User Variable    CONTEXT
    ...    type=string
    ...    description=Which Kubernetes context to operate within.
    ...    pattern=\w*
    ...    default=default
    ...    example=my-main-cluster

    Set Suite Variable    ${KUBERNETES_DISTRIBUTION_BINARY}    ${KUBERNETES_DISTRIBUTION_BINARY}
    Set Suite Variable    ${RESOURCE_NAME}    ${RESOURCE_NAME}
    Set Suite Variable    ${NAMESPACE}    ${NAMESPACE}
    Set Suite Variable    ${env}    {"KUBECONFIG":"./${kubeconfig.key}"}

    # Verify cluster connectivity
    RW.K8sHelper.Verify Cluster Connectivity
    ...    binary=${KUBERNETES_DISTRIBUTION_BINARY}
    ...    context=${CONTEXT}
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}

