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
Library             RW.K8sHelper
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
    Set Suite Variable    ${KUBERNETES_DISTRIBUTION_BINARY}    ${KUBERNETES_DISTRIBUTION_BINARY}
    Set Suite Variable    ${CONTEXT}    ${CONTEXT}
    Set Suite Variable    ${NAMESPACE}    ${NAMESPACE}
    Set Suite Variable    ${STATEFULSET_NAME}    ${STATEFULSET_NAME}
    Set Suite Variable    ${JENKINS_SA_USERNAME}    ${JENKINS_SA_USERNAME}
    Set Suite Variable    ${JENKINS_SA_TOKEN}    ${JENKINS_SA_TOKEN}
    Set Suite Variable    ${env}    {"KUBECONFIG":"./${kubeconfig.key}"}

    # Verify cluster connectivity
    RW.K8sHelper.Verify Cluster Connectivity
    ...    binary=${KUBERNETES_DISTRIBUTION_BINARY}
    ...    context=${CONTEXT}
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}

*** Tasks ***
Query The Jenkins Kubernetes Workload HTTP Endpoint in Kubernetes StatefulSet `${STATEFULSET_NAME}`
    [Documentation]    Performs a curl within the jenkins statefulset kubernetes workload to determine if the pod is up and healthy, and can serve requests.
    [Tags]    access:read-only  HTTP    Curl    Web    Code    OK    Available    Jenkins    HTTP    Endpoint    API
    ${rsp}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} exec statefulset/${STATEFULSET_NAME} --context=${CONTEXT} -n ${NAMESPACE} -- curl -s -o /dev/null -w "\%{http_code}" localhost:8080/login
    ...    show_in_rwl_cheatsheet=true
    ...    render_in_commandlist=true
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    # Check if Jenkins HTTP response does not contain 200
    ${not_contains_200}=    Run Keyword And Return Status    Should Not Contain    ${rsp.stdout}    200
    IF    ${not_contains_200}
        RW.Core.Add Issue
        ...    severity=2
        ...    expected=The jenkins login page should be available and return a 200
        ...    actual=The jenkins login page returned a non-200 response
        ...    title=Jenkins HTTP Check Failed in Namespace `${NAMESPACE}`
        ...    details=Check if the statefulset is unhealthy as the endpoint returned: ${rsp.stdout} from within the pod workload.
        ...    reproduce_hint=Test Jenkins endpoint accessibility from within the pod
        ...    next_steps=Check Jenkins pod logs and statefulset health in namespace `${NAMESPACE}`
    END
    ${rsp}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} exec statefulset/${STATEFULSET_NAME} --context=${CONTEXT} -n ${NAMESPACE} -- curl -s localhost:8080/api/json?pretty=true --user $${JENKINS_SA_USERNAME.key}:$${JENKINS_SA_TOKEN.key}
    ...    secret__jenkins_sa_username=${JENKINS_SA_USERNAME}
    ...    secret__jenkins_sa_token=${JENKINS_SA_TOKEN}
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    show_in_rwl_cheatsheet=true
    ...    render_in_commandlist=true
    RW.Core.Add Pre To Report    Remote API Info:\n${rsp.stdout}
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Commands Used: ${history}


Query For Stuck Jenkins Jobs in Kubernetes Statefulset Workload `${STATEFULSET_NAME}`
    [Documentation]    Performs a curl within the jenkins statefulset kubernetes workload to check for stuck jobs in the jenkins piepline queue.
    [Tags]   access:read-only   HTTP    Curl    Web    Code    OK    Available    Queue    Stuck    Jobs    Jenkins
    ${rsp}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} exec statefulset/${STATEFULSET_NAME} --context=${CONTEXT} -n ${NAMESPACE} -- curl -s localhost:8080/queue/api/json --user $${JENKINS_SA_USERNAME.key}:$${JENKINS_SA_TOKEN.key} | jq -r '.items[] | select((.stuck == true) or (.blocked == true)) | "Why: " + .why + "\\nBlocked: " + (.blocked|tostring) + "\\nStuck: " + (.stuck|tostring)'
    ...    secret__jenkins_sa_username=${JENKINS_SA_USERNAME}
    ...    secret__jenkins_sa_token=${JENKINS_SA_TOKEN}
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    show_in_rwl_cheatsheet=true
    ...    render_in_commandlist=true
    # Check if Jenkins has stuck jobs
    ${contains_stuck}=    Run Keyword And Return Status    Should Contain    ${rsp.stdout}    Stuck
    IF    ${contains_stuck}
        RW.Core.Add Issue
        ...    severity=2
        ...    expected=The Jenkins pipeline should not have any stuck jobs
        ...    actual=The Jenkins pipeline has stuck jobs in the queue
        ...    title=Stuck Jobs in Jenkins Pipeline in Namespace `${NAMESPACE}`
        ...    details=We found stuck jobs in the output: ${rsp.stdout} - check the jenkins console for further details on how to unstuck them.
        ...    reproduce_hint=Check Jenkins queue API and console for stuck job details
        ...    next_steps=Review Jenkins console, check for resource constraints, and manually unstick jobs if needed
    END
    RW.Core.Add Pre To Report    Queue Information:\n${rsp.stdout}
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Commands Used: ${history}