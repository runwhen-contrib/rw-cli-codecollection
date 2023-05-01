*** Settings ***
Documentation       This taskset runs general troubleshooting checks against argocd application objects within a namespace.
Metadata            Author    Shea Stewart
Metadata            Display Name    Kubernetes ArgoCD Application Troubleshoot
Metadata            Supports    Kubernetes,AKS,EKS,GKE,OpenShift,ArgoCD
Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             OperatingSystem
Library             DateTime
Library             Collections

Suite Setup         Suite Initialization

Force Tags          k8s    kubernetes    kube    k8    argocd


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
    ${binary_name}=    RW.Core.Import User Variable    binary_name
    ...    description=The Kubernetes cli binary to use.
    ...    default=kubectl
    ...    enum=kubectl,oc
    ${NAMESPACE}=    RW.Core.Import User Variable    NAMESPACE
    ...    type=string
    ...    description=The name of the Kubernetes namespace to scope actions and searching to. 
    ...    pattern=\w*
    ...    example=my-app-namespace
    ${CONTEXT}=    RW.Core.Import User Variable    CONTEXT
    ...    type=string
    ...    description=Which Kubernetes context to operate within.
    ...    pattern=\w*
    ...    example=my-main-cluster
    ${ERROR_PATTERN}=    RW.Core.Import User Variable    ERROR_PATTERN
    ...    type=string
    ...    description=The error pattern to use when grep-ing logs.
    ...    pattern=\w*
    ...    example=(Error|Exception)
    ...    default=(Error|Exception)
    ${APPLICATION}=    RW.Core.Import User Variable    APPLICATION
    ...    type=string
    ...    description=The name of the ArgoCD Application to query. Leave blank to query all applications within the namespace. 
    ...    pattern=\w*
    ...    example=otel-demo
    ...    default=''
    Set Suite Variable    ${kubeconfig}    ${kubeconfig}
    Set Suite Variable    ${binary_name}    ${binary_name}
    Set Suite Variable    ${kubectl}    ${kubectl}
    Set Suite Variable    ${CONTEXT}    ${CONTEXT}
    Set Suite Variable    ${NAMESPACE}    ${NAMESPACE}
    Set Suite Variable    ${ERROR_PATTERN}    ${ERROR_PATTERN}
    Set Suite Variable    ${APPLICATION}    ${APPLICATION}
    Set Suite Variable    ${env}    {"KUBECONFIG":"./${kubeconfig.key}"}

*** Tasks ***
Fetch Application Sync Status
    [Documentation]    Shows the sync status of the ArgoCD application. 
    [Tags]    Application    Sync
    ${app_sync_status}=    RW.CLI.Run Cli
    ...    cmd=${binary_name} get applications.argoproj.io ${APPLICATION} -n ${NAMESPACE} --context ${CONTEXT} -o jsonpath='Application Name: {.metadata.name}, Sync Status: {.status.sync.status}'
    ...    target_service=${kubectl}
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Summary of application sync status in namespace: ${NAMESPACE}
    RW.Core.Add Pre To Report    ${app_sync_status}
    RW.Core.Add Pre To Report    Commands Used:\n${history}
