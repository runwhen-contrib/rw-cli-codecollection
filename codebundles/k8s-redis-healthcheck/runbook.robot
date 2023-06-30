*** Settings ***
Documentation       This taskset collects information on your redis workload in your Kubernetes cluster and raises issues when health checks fail.
Metadata            Author    jon-funk
Metadata            Display Name    Kubernetes Redis Healthcheck
Metadata            Supports    Kubernetes,AKS,EKS,GKE,OpenShift,Redis

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             OperatingSystem
Library             DateTime
Library             Collections

Suite Setup         Suite Initialization


*** Tasks ***
Ping Redis Workload
    [Documentation]    Verifies that a PING can be peformed against the redis workload.
    [Tags]    redis    cli    ping    pong    alive    probe    ready
    ${rsp}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} exec deployment/${DEPLOYMENT_NAME} --context=${CONTEXT} -n ${NAMESPACE} -- redis-cli PING
    ...    render_in_commandlist=true
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    RW.CLI.Parse Cli Output By Line
    ...    rsp=${rsp}
    ...    set_severity_level=2
    ...    set_issue_expected=The Redis workload returned a PONG in response to PING
    ...    set_issue_actual=The Redis workload was unable to properly repond to the PING request
    ...    set_issue_title=Redis PING Failed In Namespace ${NAMESPACE} For Redis Deployment ${DEPLOYMENT_NAME}
    ...    set_issue_details=Found $_line in namespace ${NAMESPACE}\nCheck if the redis workload is healthy and available. Attempt to run a 'redis-cli PING' directly on the workload and verify the response which should be PONG.
    ...    _line__raise_issue_if_ncontains=PONG
    RW.Core.Add Pre To Report    Redis Response:\n${rsp.stdout}
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Commands Used: ${history}

Verify Redis Read Write Operation
    [Documentation]    Attempts to perform a write and read operation on the redis workload, checking that a key can be set, incremented, and read from.
    [Tags]    redis    cli    increment    health    check    read    write
    ${set_op}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} exec deployment/${DEPLOYMENT_NAME} --context=${CONTEXT} -n ${NAMESPACE} -- redis-cli SET ${REDIS_HEALTHCHECK_KEY} 0
    ...    render_in_commandlist=true
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ${incr_op}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} exec deployment/${DEPLOYMENT_NAME} --context=${CONTEXT} -n ${NAMESPACE} -- redis-cli INCR ${REDIS_HEALTHCHECK_KEY}
    ...    render_in_commandlist=true
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ${get_op}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} exec deployment/${DEPLOYMENT_NAME} --context=${CONTEXT} -n ${NAMESPACE} -- redis-cli GET ${REDIS_HEALTHCHECK_KEY}
    ...    render_in_commandlist=true
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    RW.CLI.Parse Cli Output By Line
    ...    rsp=${get_op}
    ...    set_severity_level=1
    ...    set_issue_expected=The redis workload successfully incremented the healthcheck key.
    ...    set_issue_actual=The redis workload failed to increment the key as expected.
    ...    set_issue_title=Redis Read Write Operation Failure In Namespace ${NAMESPACE} For Redis Deployment ${DEPLOYMENT_NAME}
    ...    set_issue_details=Found $_line in namespace ${NAMESPACE}\nCheck the PVC that the redis workload depends on and verify it's healthy. Try use 'redis-cli INCR ${REDIS_HEALTHCHECK_KEY}' yourself on the workload.
    ...    _line__raise_issue_if_neq=1
    RW.Core.Add Pre To Report    Redis Response For Key ${REDIS_HEALTHCHECK_KEY}:${get_op.stdout}
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Commands Used: ${history}


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
    ${DEPLOYMENT_NAME}=    RW.Core.Import User Variable    DEPLOYMENT_NAME
    ...    type=string
    ...    description=Used to target the redis resource for the health check.
    ...    pattern=\w*
    ...    example=o-redis
    ${REDIS_HEALTHCHECK_KEY}=    RW.Core.Import User Variable    REDIS_HEALTHCHECK_KEY
    ...    type=string
    ...    description=The key used to perform read/write operations on to validate storage.
    ...    pattern=\w*
    ...    example=runwhen_task_rw_healthcheck
    ...    default=runwhen_task_rw_healthcheck
    Set Suite Variable    ${kubeconfig}    ${kubeconfig}
    Set Suite Variable    ${kubectl}    ${kubectl}
    Set Suite Variable    ${KUBERNETES_DISTRIBUTION_BINARY}    ${KUBERNETES_DISTRIBUTION_BINARY}
    Set Suite Variable    ${CONTEXT}    ${CONTEXT}
    Set Suite Variable    ${NAMESPACE}    ${NAMESPACE}
    Set Suite Variable    ${DEPLOYMENT_NAME}    ${DEPLOYMENT_NAME}
    Set Suite Variable    ${REDIS_HEALTHCHECK_KEY}    ${REDIS_HEALTHCHECK_KEY}
    Set Suite Variable    ${env}    {"KUBECONFIG":"./${kubeconfig.key}"}
