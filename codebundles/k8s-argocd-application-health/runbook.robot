*** Settings ***
Documentation       This taskset collects information and runs general troubleshooting checks against argocd application objects within a namespace.
Metadata            Author    Shea Stewart
Metadata            Display Name    Kubernetes ArgoCD Application Health & Troubleshoot
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
    ${APPLICATION_TARGET_NAMESPACE}=    RW.Core.Import User Variable    APPLICATION_TARGET_NAMESPACE
    ...    type=string
    ...    description=The name of the Kubernetes namespace where the application resources are deployed to. 
    ...    pattern=\w*
    ...    example=app-target-namespace
    ${APPLICATION_APP_NAMESPACE}=    RW.Core.Import User Variable    APPLICATION_APP_NAMESPACE
    ...    type=string
    ...    description=The name of the Kubernetes namespace in which the ArgoCD Application resource exists. 
    ...    pattern=\w*
    ...    example=app-namespace
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
Fetch Application Sync Status & Health
    [Documentation]    Shows the sync status and health of the ArgoCD application. 
    [Tags]    Application    Sync    Health
    ${app_sync_status}=    RW.CLI.Run Cli
    ...    cmd=${binary_name} get applications.argoproj.io ${APPLICATION} -n ${APPLICATION_APP_NAMESPACE} --context ${CONTEXT} -o jsonpath='Application Name: {.metadata.name}, Sync Status: {.status.sync.status}, Health Status: {.status.health.status}, Message: {.status.conditions[].message}'
    ...    target_service=${kubectl}
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Summary of application sync status in namespace: ${APPLICATION_APP_NAMESPACE}
    RW.Core.Add Pre To Report    ${app_sync_status.stdout}
    RW.Core.Add Pre To Report    Commands Used:\n${history}

Fetch Last Sync Operation Details
    [Documentation]    Fetches the last argocd sync operation staus. 
    [Tags]    Application    SyncOperation    History
    ${last_sync_status}=    RW.CLI.Run Cli
    ...    cmd=${binary_name} get applications.argoproj.io ${APPLICATION} -n ${APPLICATION_APP_NAMESPACE} --context ${CONTEXT} -o json | jq -r '"Application Name: " + .metadata.name + "\nApplication Namespace: "+ .metadata.namespace + "\nLast Sync Start Time: " + .status.operationState.finishedAt + "\nLast Sync Finish Time: " + .status.operationState.startedAt + "\nLast Sync Status: " + .status.operationState.phase + "\nLast Sync Message: " + .status.operationState.message'
    ...    target_service=${kubectl}
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Summary of application sync status in namespace: ${APPLICATION_APP_NAMESPACE}
    RW.Core.Add Pre To Report    ${last_sync_status.stdout}
    RW.Core.Add Pre To Report    Commands Used:\n${history}


Fetch Unhealthy Application Resources
    [Documentation]    Displays all resources that are not in a healthy state. 
    [Tags]    Resources    Unhealthy    SyncStatus
    ${unhealthy_resources}=    RW.CLI.Run Cli
    ...    cmd=${binary_name} get applications.argoproj.io ${APPLICATION} -n ${APPLICATION_APP_NAMESPACE} --context ${CONTEXT} -o json | jq -r '.status.resources[] | select(.health.status != null) | select(.health.status != "Healthy") | {name,kind,namespace,health}'
    ...    target_service=${kubectl}
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    List of unhealthy resources for application: ${APPLICATION}
    RW.Core.Add Pre To Report    ${unhealthy_resources.stdout}
    RW.Core.Add Pre To Report    Commands Used:\n${history}

Scan For Errors in Pod Logs
    [Documentation]    Grep for the error pattern across all pods managed by this Applications deployments.  
    [Tags]    Error    Logs    Deployments
    ${log_errors}=    RW.CLI.Run Cli
    ...    cmd=for deployment_name in $(kubectl get deployments -l argocd.argoproj.io/instance=${APPLICATION_TARGET_NAMESPACE}_${APPLICATION} -o=custom-columns=NAME:.metadata.name --no-headers -n ${APPLICATION_TARGET_NAMESPACE}); do echo "\nDEPLOYMENT NAME: $deployment_name \n" && kubectl logs deployment/$deployment_name --tail=50 -n ${APPLICATION_TARGET_NAMESPACE} | grep -E '${ERROR_PATTERN}'; done
    ...    target_service=${kubectl}
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Errors found in pods logs for: ${APPLICATION}
    RW.Core.Add Pre To Report    ${log_errors.stdout}
    RW.Core.Add Pre To Report    Commands Used:\n${history}

Fully Describe Application
    [Documentation]    Describe all details regarding the application. Useful if reviewing all content.   
    [Tags]    Application    Describe    
    ${application_describe}=    RW.CLI.Run Cli
    ...    cmd=${binary_name} describe applications.argoproj.io ${APPLICATION} -n ${APPLICATION_APP_NAMESPACE} --context ${CONTEXT}
    ...    target_service=${kubectl}
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Full description of ArgoCD application: ${APPLICATION}
    RW.Core.Add Pre To Report    ${application_describe.stdout}
    RW.Core.Add Pre To Report    Commands Used:\n${history}
