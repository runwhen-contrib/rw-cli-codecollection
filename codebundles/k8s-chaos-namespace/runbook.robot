*** Settings ***
Documentation       Provides chaos injection tasks for Kubernetes namespaces. These are destructive tasks and the expectation is that you can heal these changes by enabling your GitOps reconciliation.
Metadata            Author    jon-funk
Metadata            Display Name    Kubernetes Namespace Chaos Engineering
Metadata            Supports    Kubernetes    Chaos Engineering    Namespace
Metadata            Builder

Library             BuiltIn
Library             RW.Core
Library             RW.platform
Library             OperatingSystem
Library             String
Library             Process

Suite Setup         Suite Initialization

*** Tasks ***
Test Namespace Highly Available
    [Documentation]   Randomly selects up to 10 pods in a namespace to delete to test HA
    [Tags]  Kubernetes    Namespace    Deployments    Pods    Highly Available 
    ${process}=    Run Process    ${CURDIR}/delete_random_pods.sh    env=${env}
    RW.Core.Add Pre To Report    ${process.stdout}

Test Node Drain
    [Documentation]   Drains a random node to check disruption handling
    [Tags]  Kubernetes    Nodes    Drain    Disruption
    ${process}=    Run Process    ${CURDIR}/drain_node.sh    env=${env}
    RW.Core.Add Pre To Report    ${process.stdout}

Mangle Service Selector
    [Documentation]   Breaks a service's label selector to cause a network disruption
    [Tags]  Kubernetes    networking    Services    Selector
    ${process}=    Run Process    ${CURDIR}/change_service_selector.sh    env=${env}
    RW.Core.Add Pre To Report    ${process.stdout}

Mangle Service Port
    [Documentation]   Changes a service's port to cause a network disruption
    [Tags]  Kubernetes    networking    Services    Port
    ${process}=    Run Process    ${CURDIR}/change_service_port.sh    env=${env}
    Log    ${process.stderr}
    RW.Core.Add Pre To Report    ${process.stdout}

Fill Pod Tmp
    [Documentation]   Attaches to a pod and fills the /tmp directory with random data
    [Tags]  Kubernetes    pods    volumes    tmp
    ${process}=    Run Process    ${CURDIR}/expand_tmp.sh    env=${env}
    Log    ${process.stderr}
    RW.Core.Add Pre To Report    ${process.stdout}

*** Keywords ***
Suite Initialization
    ${KUBECONFIG}=    RW.Core.Import Secret     KUBECONFIG
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

    Set Suite Variable    ${KUBECONFIG}    ${KUBECONFIG.value}
    Set Suite Variable    ${CONTEXT}    ${CONTEXT}
    Set Suite Variable    ${NAMESPACE}    ${NAMESPACE}

    Set Suite Variable
    ...    &{env}
    ...    KUBECONFIG=${KUBECONFIG}
    ...    CONTEXT=${CONTEXT}
    ...    NAMESPACE=${NAMESPACE}
