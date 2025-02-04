*** Settings ***
Documentation       Generates a report of the reconciliation errors for fluxcd in your cluster.
Metadata            Author    jon-funk
Metadata            Display Name    Kubernetes Fluxcd Reconciliation Report
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
Health Check Flux Reconciliation in Kubernetes Namespace `${FLUX_NAMESPACE}`
    [Documentation]   Fetches reconciliation logs for flux and creates a report for them.
    [Tags]  Kubernetes    Namespace    Flux
    ${process}=    RW.CLI.Run Bash File    flux_reconcile_report.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    IF    ${process.returncode} != 0
        RW.Core.Add Issue    title=Errors in Flux Controller Reconciliation
        ...    severity=3
        ...    expected=No errors in Flux controller reconciliation.
        ...    actual=Flux controllers have errors in their reconciliation process.
        ...    reproduce_hint=Run flux_reconcile_report.sh manually to see the errors.
        ...    next_steps=Inspect Flux logs to determine which objects are failing to reconcile.
        ...    details=${process.stdout}
    END
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
    ${FLUX_NAMESPACE}=    RW.Core.Import User Variable   FLUX_NAMESPACE
    ...    type=string
    ...    description=The namespace where the flux controllers reside. Typically flux-system.
    ...    pattern=\w*
    ...    default=flux-system
    ...    example=flux-system


    Set Suite Variable    ${CONTEXT}    ${CONTEXT}
    Set Suite Variable    ${FLUX_NAMESPACE}    ${FLUX_NAMESPACE}
    Set Suite Variable    ${kubeconfig}    ${kubeconfig}
    Set Suite Variable
    ...    &{env}
    ...    KUBECONFIG=${kubeconfig.key}
    ...    CONTEXT=${CONTEXT}
    ...    FLUX_NAMESPACE=${FLUX_NAMESPACE}
