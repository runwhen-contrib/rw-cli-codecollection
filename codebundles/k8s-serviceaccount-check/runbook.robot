*** Settings ***
Documentation       This taskset provides tasks to troubleshoot service accounts in a Kubernetes namespace.
Metadata            Author    stewartshea
Metadata            Display Name    Kubernetes Service Account Check
Metadata            Supports    Kubernetes,AKS,EKS,GKE,OpenShift
Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             RW.K8sHelper
Library             OperatingSystem
Library             DateTime
Library             Collections
Library             String

Suite Setup         Suite Initialization


*** Keywords ***
Suite Initialization
    ${kubeconfig}=    RW.Core.Import Secret
    ...    kubeconfig
    ...    type=string
    ...    description=The kubernetes kubeconfig yaml containing connection configuration used to connect to cluster(s).
    ...    pattern=\w*
    ...    example=For examples, start here https://kubernetes.io/docs/concepts/configuration/organize-cluster-access-kubeconfig/
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
    Set Suite Variable    ${KUBERNETES_DISTRIBUTION_BINARY}    ${KUBERNETES_DISTRIBUTION_BINARY}
    Set Suite Variable    ${CONTEXT}    ${CONTEXT}
    Set Suite Variable    ${NAMESPACE}    ${NAMESPACE}
    Set Suite Variable    ${SERVICE_ACCOUNT}    ${SERVICE_ACCOUNT}
    Set Suite Variable    ${env}    {"KUBECONFIG":"./${kubeconfig.key}"}

    # Verify cluster connectivity
    RW.K8sHelper.Verify Cluster Connectivity
    ...    binary=${KUBERNETES_DISTRIBUTION_BINARY}
    ...    context=${CONTEXT}
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}

*** Tasks ***
Test Service Account Access to Kubernetes API Server in Namespace `${NAMESPACE}`
    [Documentation]    Runs a curl pod as a specific serviceaccount and attempts to all the Kubernetes API server with the mounted token
    [Tags]    ServiceAccount    Curl    APIServer    RBAC    ${SERVICE_ACCOUNT}    ${NAMESPACE}        data:config
    ${sa_access}=    RW.CLI.Run Cli
    ...    cmd=apiserver=https://kubernetes.default.svc; namespace=${NAMESPACE}; context=${CONTEXT}; resource=""; serviceaccount=${SERVICE_ACCOUNT}; ${KUBERNETES_DISTRIBUTION_BINARY} run curl-pod --image=curlimages/curl:latest --restart=Never --overrides="{ \\"spec\\": { \\"serviceAccountName\\": \\"$serviceaccount\\" } }" -n $namespace --context=$context --command -- sleep infinity && echo "Waiting for the curl-pod to be running..." && ${KUBERNETES_DISTRIBUTION_BINARY} wait --for=condition=Ready pod/curl-pod --timeout=20s -n $namespace --context=$context && TOKEN=$(${KUBERNETES_DISTRIBUTION_BINARY} exec curl-pod -n $namespace --context=$context -- cat /var/run/secrets/kubernetes.io/serviceaccount/token) && echo "Performing a curl request to the Kubernetes API..." && ${KUBERNETES_DISTRIBUTION_BINARY} exec curl-pod -n $namespace --context=$context -- curl -s -k -H "Authorization: Bearer $TOKEN" $apiserver$resource && echo "Cleaning up..." && ${KUBERNETES_DISTRIBUTION_BINARY} delete pod curl-pod -n $namespace --context=$context && echo "Done"
    ...    show_in_rwl_cheatsheet=true
    ...    render_in_commandlist=true
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ${error_message}=    RW.CLI.Run Cli
    ...    cmd=echo "${sa_access.stdout}" | grep message | sed 's/ *$//' | tr -d '\n'
    ...    env=${env}
    ...    include_in_history=false
    # Check if the service account access contains "Forbidden" and create issue if so
    ${contains_forbidden}=    Run Keyword And Return Status    Should Contain    ${sa_access.stdout}    Forbidden
    IF    ${contains_forbidden}
        RW.Core.Add Issue
        ...    severity=3
        ...    reproduce_hint=Run a curl pod as the desired service account and try to curl the API endpoint
        ...    expected=Service account `${SERVICE_ACCOUNT}` in namespace `${NAMESPACE}` should be able to access the Kubernetes API
        ...    actual=Service Account `${SERVICE_ACCOUNT}` in namespace `${NAMESPACE}` cannot access Kubernetes API in namespace `${NAMESPACE}`
        ...    title=Service Account `${SERVICE_ACCOUNT}` Cannot Access Kubernetes API in Namespace `${NAMESPACE}`
        ...    details=Service account `${SERVICE_ACCOUNT}` tried to access the Kubernetes API with the following error message:\n${error_message.stdout}
        ...    next_steps=Verify RBAC Configuration for Service Account `${SERVICE_ACCOUNT}` in namespace `${NAMESPACE}`
    END
    RW.Core.Add Pre To Report    Test Output:\n${sa_access.stdout}
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Commands Used: ${history}

