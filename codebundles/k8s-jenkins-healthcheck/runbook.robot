*** Settings ***
Documentation       This taskset collects information about perstistent volumes and persistent volume claims to 
...    validate health or help troubleshoot potential issues.
Metadata            Author    jon-funk
Metadata            Display Name    Kubernetes Jenkins Healthcheck
Metadata            Supports    Kubernetes,AKS,EKS,GKE,OpenShift,Jenkins
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
    ${STATEFULSET_NAME}=    RW.Core.Import User Variable    STATEFULSET_NAME
    ...    type=string
    ...    description=Used to target the resource for queries and filtering events.
    ...    pattern=\w*
    ...    example=jenkins
    ${JENKINS_SA_USERNAME}=    RW.Core.Import Secret   JENKINS_SA_USERNAME
    ...    type=string
    ...    description=The username associated with the API token, typically the username.
    ...    pattern=\w*
    ...    example=my-username
    ...    default=
    ${JENKINS_SA_TOKEN}=    RW.Core.Import Secret    JENKINS_SA_TOKEN
    ...    type=string
    ...    description=The API token generated and managed by jenkins in the user configuration settings.
    ...    pattern=\w*
    ...    example=my-secret-token
    ...    default=
    Set Suite Variable    ${kubeconfig}    ${kubeconfig}
    Set Suite Variable    ${kubectl}    ${kubectl}
    Set Suite Variable    ${KUBERNETES_DISTRIBUTION_BINARY}    ${KUBERNETES_DISTRIBUTION_BINARY}
    Set Suite Variable    ${CONTEXT}    ${CONTEXT}
    Set Suite Variable    ${NAMESPACE}    ${NAMESPACE}
    Set Suite Variable    ${STATEFULSET_NAME}    ${STATEFULSET_NAME}
    Set Suite Variable    ${JENKINS_SA_USERNAME}    ${JENKINS_SA_USERNAME}
    Set Suite Variable    ${JENKINS_SA_TOKEN}    ${JENKINS_SA_TOKEN}
    Set Suite Variable    ${env}    {"KUBECONFIG":"./${kubeconfig.key}"}

*** Tasks ***
Query The Jenkins Kubernetes Workload HTTP Endpoint
    [Documentation]    Performs a curl within the jenkins statefulset kubernetes workload to determine if the pod is up and healthy, and can serve requests.
    [Tags]    HTTP    Curl    Web    Code    OK    Available    Jenkins    HTTP    Endpoint    API
    ${rsp}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} exec statefulset/${STATEFULSET_NAME} --context=${CONTEXT} -n ${NAMESPACE} -- curl -s -o /dev/null -w "\%{http_code}" localhost:8080/login
    ...    render_in_commandlist=true
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    RW.CLI.Parse Cli Output By Line
    ...    rsp=${rsp}
    ...    set_severity_level=2
    ...    set_issue_expected=The jenkins login page should be available and return a 200
    ...    set_issue_actual=The jenkins login page returned a non-200 response
    ...    set_issue_title=Jenkins HTTP Check Failed
    ...    set_issue_details=Check if the statefulset is unhealthy as the endpoint returned: $_line from within the pod workload. 
    ...    _line__raise_issue_if_ncontains=200
    ${rsp}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} exec statefulset/${STATEFULSET_NAME} --context=${CONTEXT} -n ${NAMESPACE} -- curl -s localhost:8080/api/json?pretty=true --user $${JENKINS_SA_USERNAME.key}:$${JENKINS_SA_TOKEN.key}
    ...    secret__jenkins_sa_username=${JENKINS_SA_USERNAME}
    ...    secret__jenkins_sa_token=${JENKINS_SA_TOKEN}
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    render_in_commandlist=true
    RW.Core.Add Pre To Report    Remote API Info:\n${rsp.stdout}
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Commands Used: ${history}


Query For Stuck Jenkins Jobs
    [Documentation]    Performs a curl within the jenkins statefulset kubernetes workload to check for stuck jobs in the jenkins piepline queue.
    [Tags]    HTTP    Curl    Web    Code    OK    Available    Queue    Stuck    Jobs    Jenkins
    ${rsp}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} exec statefulset/${STATEFULSET_NAME} --context=${CONTEXT} -n ${NAMESPACE} -- curl -s localhost:8080/queue/api/json --user $${JENKINS_SA_USERNAME.key}:$${JENKINS_SA_TOKEN.key} | jq -r '.items[] | select((.stuck == true) or (.blocked == true)) | "Why: " + .why + "\nBlocked: " + (.blocked|tostring) + "\nStuck: " + (.stuck|tostring)'
    ...    secret__jenkins_sa_username=${JENKINS_SA_USERNAME}
    ...    secret__jenkins_sa_token=${JENKINS_SA_TOKEN}
    ...    env=${env}
    ...    target_service=${kubectl}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    render_in_commandlist=true
    RW.CLI.Parse Cli Output By Line
    ...    rsp=${rsp}
    ...    set_severity_level=2
    ...    set_issue_expected=The Jenkins pipeline should not have any stuck jobs
    ...    set_issue_actual=The Jenkins pipeline has stuck jobs in the queue
    ...    set_issue_title=Stuck Jobs in Jenkins Pipeline
    ...    set_issue_details=We found stuck jobs in the stdout: $_stdout - check the jenkins console for further details on how to unstuck them.
    ...    _line__raise_issue_if_contains=Stuck
    RW.Core.Add Pre To Report    Queue Information:\n${rsp.stdout}
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Commands Used: ${history}