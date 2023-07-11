*** Settings ***
Documentation       This taskset provides tasks to troubleshoot service accounts in a Kubernetes namespace.
Metadata            Author    stewartshea
Metadata            Display Name    Kubernetes Service Account Check
Metadata            Supports    Kubernetes,AKS,EKS,GKE,OpenShift,Redis
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
    ${KUBERNETES_DISTRIBUTION_BINARY}=    RW.Core.Import User Variable    KUBERNETES_DISTRIBUTION_BINARY
    ...    type=string
    ...    description=Which binary to use for Kubernetes CLI commands.
    ...    enum=[kubectl,oc]
    ...    example=kubectl
    ...    default=kubectl
    ${CONTEXT}=    RW.Core.Import User Variable    CONTEXT
    ...    type=string
    ...    description=Which Kubernetes context to operate within.
    ...    pattern=\w*
    ...    example=my-main-cluster
    ${NAMESPACE}=    RW.Core.Import User Variable    NAMESPACE
    ...    type=string
    ...    description=The name of the namespace to search.   
    ...    pattern=\w*
    ...    example=otel-demo
    ...    default=
    ${SERVICE_ACCOUNT}=    RW.Core.Import User Variable    SERVICE_ACCOUNT
    ...    type=string
    ...    description=The name of the namespace to search.   
    ...    pattern=\w*
    ...    example=default
    ...    default=default
    Set Suite Variable    ${kubeconfig}    ${kubeconfig}
    Set Suite Variable    ${kubectl}    ${kubectl}
    Set Suite Variable    ${KUBERNETES_DISTRIBUTION_BINARY}    ${KUBERNETES_DISTRIBUTION_BINARY}
    Set Suite Variable    ${CONTEXT}    ${CONTEXT}
    Set Suite Variable    ${NAMESPACE}    ${NAMESPACE}
    Set Suite Variable    ${SERVICE_ACCOUNT}    ${SERVICE_ACCOUNT}
    Set Suite Variable    ${env}    {"KUBECONFIG":"./${kubeconfig.key}"}

*** Tasks ***
Test Service Account Access to Kubernetes API Server
    [Documentation]    Runs a curl pod as a specific serviceaccount and attempts to all the Kubernetes API server with the mounted token
    [Tags]    ServiceAccount    Curl    APIServer    RBAC
    ${sa_access}=    RW.CLI.Run Cli
    ...    cmd=apiserver=https://kubernetes.default.svc; namespace=${NAMESPACE}; context=${CONTEXT}; resource=""; serviceaccount=${SERVICE_ACCOUNT}; ${KUBERNETES_DISTRIBUTION_BINARY} run curl-pod --image=curlimages/curl:latest --restart=Never --overrides="{ \\"spec\\": { \\"serviceAccountName\\": \\"$serviceaccount\\" } }" -n $namespace --context=$context --command -- sleep infinity && echo "Waiting for the curl-pod to be running..." && ${KUBERNETES_DISTRIBUTION_BINARY} wait --for=condition=Ready pod/curl-pod --timeout=20s -n $namespace --context=$context && TOKEN=$(${KUBERNETES_DISTRIBUTION_BINARY} exec curl-pod -n $namespace --context=$context -- cat /var/run/secrets/kubernetes.io/serviceaccount/token) && echo "Performing a curl request to the Kubernetes API..." && ${KUBERNETES_DISTRIBUTION_BINARY} exec curl-pod -n $namespace --context=$context -- curl -s -k -H "Authorization: Bearer $TOKEN" $apiserver$resource && echo "Cleaning up..." && ${KUBERNETES_DISTRIBUTION_BINARY} delete pod curl-pod -n $namespace --context=$context && echo "Done!"
    ...    render_in_commandlist=true
    ...    target_service=${kubectl}
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    RW.Core.Add Pre To Report    Test Output:\n${sa_access.stdout}
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Commands Used: ${history}
