*** Settings ***
Documentation       This taskset collects information on your redis workload in your Kubernetes cluster and raises issues if any health checks fail.
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
Ping `${DEPLOYMENT_NAME}` Redis Workload
    [Documentation]    Verifies that a PING can be peformed against the redis workload.
    [Tags]    access:read-only  redis    cli    ping    pong    alive    probe    ready
    ${rsp}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} exec deployment/${DEPLOYMENT_NAME} --context=${CONTEXT} -n ${NAMESPACE} -- redis-cli PING
    ...    show_in_rwl_cheatsheet=true
    ...    render_in_commandlist=true
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    # Check if Redis PING response does not contain PONG
    ${not_contains_pong}=    Run Keyword And Return Status    Should Not Contain    ${rsp.stdout}    PONG
    IF    ${not_contains_pong}
        RW.Core.Add Issue
        ...    severity=2
        ...    expected=The Redis workload returned a PONG in response to PING
        ...    actual=The Redis workload was unable to properly respond to the PING request
        ...    title=Redis PING Failed In Namespace `${NAMESPACE}` For Redis Deployment `${DEPLOYMENT_NAME}`
        ...    details=Found ${rsp.stdout} in namespace `${NAMESPACE}`\nCheck if the redis workload is healthy and available. Attempt to run a 'redis-cli PING' directly on the workload and verify the response which should be PONG.
        ...    reproduce_hint=Test Redis connectivity using redis-cli PING command
        ...    next_steps=Check PVC health status in namespace `${NAMESPACE}`
    END
    RW.Core.Add Pre To Report    Redis Response:\n${rsp.stdout}
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Commands Used: ${history}

Verify `${DEPLOYMENT_NAME}` Redis Read Write Operation in Kubernetes
    [Documentation]    Attempts to perform a write and read operation on the redis workload, checking that a key can be set, incremented, and read from.
    [Tags]    access:read-only  redis    cli    increment    health    check    read    write
    ${set_op}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} exec deployment/${DEPLOYMENT_NAME} --context=${CONTEXT} -n ${NAMESPACE} -- redis-cli SET ${REDIS_HEALTHCHECK_KEY} 0
    ...    show_in_rwl_cheatsheet=true
    ...    render_in_commandlist=true
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ${incr_op}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} exec deployment/${DEPLOYMENT_NAME} --context=${CONTEXT} -n ${NAMESPACE} -- redis-cli INCR ${REDIS_HEALTHCHECK_KEY}
    ...    show_in_rwl_cheatsheet=true
    ...    render_in_commandlist=true
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ${get_op}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} exec deployment/${DEPLOYMENT_NAME} --context=${CONTEXT} -n ${NAMESPACE} -- redis-cli GET ${REDIS_HEALTHCHECK_KEY}
    ...    show_in_rwl_cheatsheet=true
    ...    render_in_commandlist=true
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    # Check if Redis read/write operation failed (value should be 1)
    ${value_not_one}=    Run Keyword And Return Status    Should Not Be Equal As Strings    ${get_op.stdout}    1
    IF    ${value_not_one}
        RW.Core.Add Issue
        ...    severity=1
        ...    expected=The redis workload successfully incremented the healthcheck key
        ...    actual=The redis workload failed to increment the key as expected
        ...    title=Redis Read Write Operation Failure In Namespace `${NAMESPACE}` For Redis Deployment `${DEPLOYMENT_NAME}`
        ...    details=Found ${get_op.stdout} in namespace `${NAMESPACE}`\nCheck the PVC that the redis workload depends on and verify it's healthy. Try use 'redis-cli INCR ${REDIS_HEALTHCHECK_KEY}' yourself on the workload.
        ...    reproduce_hint=Test Redis read/write operations using redis-cli commands
        ...    next_steps=Check PVC health status in namespace `${NAMESPACE}`
    END
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
    Set Suite Variable    ${KUBERNETES_DISTRIBUTION_BINARY}    ${KUBERNETES_DISTRIBUTION_BINARY}
    Set Suite Variable    ${CONTEXT}    ${CONTEXT}
    Set Suite Variable    ${NAMESPACE}    ${NAMESPACE}
    Set Suite Variable    ${DEPLOYMENT_NAME}    ${DEPLOYMENT_NAME}
    Set Suite Variable    ${REDIS_HEALTHCHECK_KEY}    ${REDIS_HEALTHCHECK_KEY}
    Set Suite Variable    ${env}    {"KUBECONFIG":"./${kubeconfig.key}"}

    # Verify cluster connectivity
    ${connectivity}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} cluster-info --context ${CONTEXT}
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    timeout_seconds=30
    IF    ${connectivity.returncode} != 0
        RW.Core.Add Issue
        ...    severity=3
        ...    expected=Kubernetes cluster should be reachable via configured kubeconfig and context `${CONTEXT}`
        ...    actual=Unable to connect to Kubernetes cluster with context `${CONTEXT}`
        ...    title=Kubernetes Cluster Connectivity Check Failed for Context `${CONTEXT}`
        ...    reproduce_hint=${KUBERNETES_DISTRIBUTION_BINARY} cluster-info --context ${CONTEXT}
        ...    details=Failed to connect to the Kubernetes cluster. This may indicate an expired kubeconfig, network connectivity issues, or the cluster being unreachable.\n\nSTDOUT:\n${connectivity.stdout}\n\nSTDERR:\n${connectivity.stderr}
        ...    next_steps=Verify kubeconfig is valid and not expired\nCheck network connectivity to the cluster API server\nVerify the context '${CONTEXT}' is correctly configured\nCheck if the cluster is running and accessible
        BuiltIn.Fatal Error    Kubernetes cluster connectivity check failed for context '${CONTEXT}'. Aborting suite.
    END
