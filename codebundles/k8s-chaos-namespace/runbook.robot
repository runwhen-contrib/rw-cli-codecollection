*** Settings ***
Documentation       Provides chaos injection tasks for Kubernetes namespaces. These are destructive tasks and the expectation is that you can heal these changes by enabling your GitOps reconciliation.
Metadata            Author    jon-funk
Metadata            Display Name    Kubernetes Namespace Chaos Engineering
Metadata            Supports    Kubernetes    Chaos Engineering    Namespace
Metadata            Builder

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             OperatingSystem
Library             String
Library             Process

Suite Setup         Suite Initialization

*** Tasks ***
Test Namespace ${NAMESPACE} Highly Available
    [Documentation]   Randomly selects up to 10 pods in a namespace to delete to test HA
    [Tags]  Kubernetes    Namespace    Deployments    Pods    Highly Available
    ${process}=    RW.CLI.Run Bash File
    ...    bash_file=delete_random_pods.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    RW.Core.Add Pre To Report    ${process.stdout}

OOMKill Pods in Namespace ${NAMESPACE}
    [Documentation]   Randomly selects n number of pods to oomkill
    [Tags]  Kubernetes    Namespace    Deployments    Pods    Highly Available    OOMkill   Memory
    ${process}=    RW.CLI.Run Bash File
    ...    bash_file=oomkill_pod.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    RW.Core.Add Pre To Report    ${process.stdout}


# TODO: discuss with team - may impact demos?
# Test Node Drain
#     [Documentation]   Drains a random node to check disruption handling
#     [Tags]  Kubernetes    Nodes    Drain    Disruption
#     ${process}=    RW.CLI.Run Bash File    drain_node.sh
#     ...    cmd_override=./drain_node.sh
#     ...    env=${env}
#     ...    secret_file__kubeconfig=${kubeconfig}
#     RW.Core.Add Pre To Report    ${process.stdout}

Mangle Service Selector In Namespace ${NAMESPACE}
    [Documentation]   Breaks a service's label selector to cause a network disruption
    [Tags]  Kubernetes    networking    Services    Selector
    ${process}=    RW.CLI.Run Bash File    change_service_selector.sh
    ...    cmd_override=./change_service_selector.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    RW.Core.Add Pre To Report    ${process.stdout}

Mangle Service Port In Namespace ${NAMESPACE}
    [Documentation]   Changes a service's port to cause a network disruption
    [Tags]  Kubernetes    networking    Services    Port
    ${process}=    RW.CLI.Run Bash File    change_service_port.sh
    ...    cmd_override=./change_service_port.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    RW.Core.Add Pre To Report    ${process.stdout}

Fill Pod Tmp In Namespace ${NAMESPACE}
    [Documentation]   Attaches to a pod and fills the /tmp directory with random data
    [Tags]  Kubernetes    pods    volumes    tmp
    ${process}=    RW.CLI.Run Bash File    expand_tmp.sh
    ...    cmd_override=./expand_tmp.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    RW.Core.Add Pre To Report    ${process.stdout}

*** Keywords ***
Suite Initialization
    ${kubeconfig}=    RW.Core.Import Secret     kubeconfig
    ...    type=string
    ...    description=The kubeconfig secret to use for authenticating with the cluster.
    ...    pattern=\w*
    ${CONTEXT}=    RW.Core.Import User Variable   CONTEXT
    ...    type=string
    ...    description=The kubernetes context to use in the kubeconfig provided.
    ...    pattern=\w*
    ${NAMESPACE}=    RW.Core.Import User Variable   NAMESPACE
    ...    type=string
    ...    description=The namespace to target for scripts.
    ...    pattern=\w*

    Set Suite Variable    ${CONTEXT}    ${CONTEXT}
    Set Suite Variable    ${NAMESPACE}    ${NAMESPACE}
    Set Suite Variable    ${kubeconfig}    ${kubeconfig}
    Set Suite Variable
    ...    &{env}
    ...    KUBECONFIG=${kubeconfig.key}
    ...    CONTEXT=${CONTEXT}
    ...    NAMESPACE=${NAMESPACE}
