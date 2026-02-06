*** Settings ***
Documentation       This taskset restarts a resource with a given set of labels, typically used with other tasksets.
Metadata            Author    jon-funk
Metadata            Display Name    Kubernetes Restart resource
Metadata            Supports    Kubernetes,AKS,EKS,GKE,OpenShift

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             OperatingSystem
Library             DateTime
Library             Collections

Suite Setup         Suite Initialization


*** Tasks ***
Get Current Resource State with Labels `${LABELS}`
    [Documentation]    Gets the current state of the resource before applying the restart for report review.
    [Tags]    access:read-only  resource    application    restart    state    yaml
    ${resource}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} --context=${CONTEXT} -n ${NAMESPACE} get daemonset,deployment,statefulset -l ${LABELS} -oyaml
    ...    show_in_rwl_cheatsheet=true
    ...    render_in_commandlist=true
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    RW.Core.Add Pre To Report    Current Resource State:\n\n${resource.stdout}
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Commands Used: ${history}

Get Resource Logs with Labels `${LABELS}`
    [Documentation]    Collects the last approximately 200 lines of logs from the resource before restarting it.
    [Tags]    access:read-only  resource    application    workload    logs    state
    ${logs}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} --context=${CONTEXT} -n ${NAMESPACE} logs -l ${LABELS} --tail=200 --limit-bytes=256000
    ...    show_in_rwl_cheatsheet=true
    ...    render_in_commandlist=true
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    RW.Core.Add Pre To Report    Resource Logs:\n\n${logs.stdout}
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Commands Used: ${history}

Restart Resource with Labels `${LABELS}` in `${CONTEXT}`
    [Documentation]    Restarts the labeled resource in an attempt to get it out of a bad state.
    [Tags]    access:read-write  resource    application    restart    pod    kill    rollout    revision
    ${resource_name}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} --context=${CONTEXT} -n ${NAMESPACE} get daemonset,deployment,statefulset -l ${LABELS} -o=jsonpath='{.items[0].kind}/{.items[0].metadata.name}'
    ...    show_in_rwl_cheatsheet=true
    ...    render_in_commandlist=true
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ${rsp}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} rollout restart ${resource_name.stdout} --context=${CONTEXT} -n ${NAMESPACE}
    ...    show_in_rwl_cheatsheet=true
    ...    render_in_commandlist=true
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    RW.Core.Add Pre To Report    Restarted the following workload: ${resource_name.stdout}
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
    ${LABELS}=    RW.Core.Import User Variable    LABELS
    ...    type=string
    ...    description=The kubectl label string to use for selecting the resource.
    ...    pattern=\w*
    ...    example=app=loadgenerator
    ...    default=
    Set Suite Variable    ${kubeconfig}    ${kubeconfig}
    Set Suite Variable    ${KUBERNETES_DISTRIBUTION_BINARY}    ${KUBERNETES_DISTRIBUTION_BINARY}
    Set Suite Variable    ${CONTEXT}    ${CONTEXT}
    Set Suite Variable    ${NAMESPACE}    ${NAMESPACE}
    Set Suite Variable    ${LABELS}    ${LABELS}
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
