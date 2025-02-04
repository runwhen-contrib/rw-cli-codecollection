*** Settings ***
Documentation       Suspends the flux reconciliation being applied to a given namespace.
Metadata            Author    jon-funk
Metadata            Display Name    Kubernetes Flux Suspend Namespace
Metadata            Supports    Kubernetes    Flux    Chaos Engineering    Namespace
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
Flux Suspend Namespace `${NAMESPACE}`
    [Documentation]   Applies a flux suspend to the spec of all flux objects reconciling in a given namespace.
    [Tags]  Kubernetes    Namespace    Flux    Suspend
    ${process}=    RW.CLI.Run Bash File    suspend_namespace.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    RW.Core.Add Pre To Report    ${process.stdout}

Unsuspend Flux for Namespace `${NAMESPACE}`
    [Documentation]   Unsuspends any suspended flux objects in a given namespace, allowing reconciliation to resume.
    [Tags]  Kubernetes    Namespace    Flux    Unsuspend
    ${process}=    RW.CLI.Run Bash File    unsuspend_namespace.sh
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
