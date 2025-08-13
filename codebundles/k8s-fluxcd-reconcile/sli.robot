*** Settings ***
Documentation       Measures failing reconciliations for fluxcd
Metadata            Author    jon-funk
Metadata            Display Name    Kubernetes Fluxcd Reconciliation Monitor
Metadata            Supports    Kubernetes Fluxcd
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
Health Check Flux Reconciliation
    [Documentation]   Measures failing reconciliations for fluxcd
    [Tags]  Kubernetes    Namespace    Flux
    ${process}=    RW.CLI.Run Bash File    flux_reconcile_report.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    Log To Console    ${process.stdout}
    IF    ${process.returncode} != 0
        RW.Core.Push Metric    0    sub_name=fluxcd_reconcile
        RW.Core.Push Metric    0
    ELSE
        RW.Core.Push Metric    1    sub_name=fluxcd_reconcile
        RW.Core.Push Metric    1
    END

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
    ${FLUX_NAMESPACE}=    RW.Core.Import User Variable   FLUX_NAMESPACE
    ...    type=string
    ...    description=The namespace where the flux controllers reside. Typically flux-system.
    ...    pattern=\w*
    ...    default=flux-system
    ...    example=flux-system


    Set Suite Variable    ${CONTEXT}    ${CONTEXT}
    Set Suite Variable    ${kubeconfig}    ${kubeconfig}
    Set Suite Variable    ${FLUX_NAMESPACE}    ${FLUX_NAMESPACE}
    Set Suite Variable
    ...    &{env}
    ...    KUBECONFIG=${kubeconfig.key}
    ...    CONTEXT=${CONTEXT}
    ...    FLUX_NAMESPACE=${FLUX_NAMESPACE}
