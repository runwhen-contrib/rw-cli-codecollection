*** Settings ***
Documentation       This taskset collects information about perstistent volumes and persistent volume claims to 
...    validate health or help troubleshoot potential issues.
Metadata            Author    Shea Stewart
Metadata            Display Name    Kubernetes Persistent Volume Healthcheck
Metadata            Supports    Kubernetes,AKS,EKS,GKE,OpenShift
Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             OperatingSystem
Library             DateTime
Library             Collections

Suite Setup         Suite Initialization


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
    ${CONTEXT}=    RW.Core.Import User Variable    CONTEXT
    ...    type=string
    ...    description=Which Kubernetes context to operate within.
    ...    pattern=\w*
    ...    example=my-main-cluster
    ${ERROR_PATTERN}=    RW.Core.Import User Variable    ERROR_PATTERN
    ...    type=string
    ...    description=The error pattern to use when grep-ing logs.
    ...    pattern=\w*
    ...    example=Error|Exception
    ...    default=Error|Exception
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
    Set Suite Variable    ${APPLICATION_TARGET_NAMESPACE}    ${APPLICATION_TARGET_NAMESPACE}
    Set Suite Variable    ${APPLICATION_APP_NAMESPACE}    ${APPLICATION_APP_NAMESPACE}
    Set Suite Variable    ${ERROR_PATTERN}    ${ERROR_PATTERN}
    Set Suite Variable    ${APPLICATION}    ${APPLICATION}
    Set Suite Variable    ${env}    {"KUBECONFIG":"./${kubeconfig.key}"}

*** Tasks ***
Fetch Kubernetes Persistent Volume Claims
    [Documentation]    Lists all persistent volume claims within the desired namespace and summarizes their status.
    [Tags]    PVC    List    Kubernetes    Storage    PersistentVolume
    ${pvc_status}=    RW.CLI.Run Cli
    ...    cmd=${binary_name} ...
    ...    target_service=${kubectl}
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    render_in_commandlist=true
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Summary of persistent volume claim status in namespace: ${pvc_status}
    RW.Core.Add Pre To Report    ${pvc_status.stdout}
    RW.Core.Add Pre To Report    Commands Used:\n${history}

