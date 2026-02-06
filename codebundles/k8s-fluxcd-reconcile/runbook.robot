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
Library             RW.K8sLog

Suite Setup         Suite Initialization

*** Tasks ***
Check FluxCD Reconciliation Health in Kubernetes Namespace `${FLUX_NAMESPACE}`
    [Documentation]   Fetches reconciliation logs for flux and creates a report for them.
    [Tags]  access:read-only    Kubernetes    Namespace    Flux
    ${process}=    RW.CLI.Run Bash File    flux_reconcile_report.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ${timestamp}=    RW.K8sLog.Extract Timestamp From Line    ${process.stdout}
    IF    ${process.returncode} != 0
        RW.Core.Add Issue    title=Errors in Flux Controller Reconciliation
        ...    severity=3
        ...    expected=No errors in Flux controller reconciliation.
        ...    actual=Flux controllers have errors in their reconciliation process.
        ...    reproduce_hint=Run flux_reconcile_report.sh manually to see the errors.
        ...    next_steps=Inspect Flux logs to determine which objects are failing to reconcile.
        ...    details=${process.stdout}
        ...    observed_at=${timestamp}
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

    # Verify cluster connectivity
    ${connectivity}=    RW.CLI.Run Cli
    ...    cmd=kubectl cluster-info --context ${CONTEXT}
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    timeout_seconds=30
    IF    ${connectivity.returncode} != 0
        RW.Core.Add Issue
        ...    severity=3
        ...    expected=Kubernetes cluster should be reachable via configured kubeconfig and context `${CONTEXT}`
        ...    actual=Unable to connect to Kubernetes cluster with context `${CONTEXT}`
        ...    title=Kubernetes Cluster Connectivity Check Failed for Context `${CONTEXT}`
        ...    reproduce_hint=kubectl cluster-info --context ${CONTEXT}
        ...    details=Failed to connect to the Kubernetes cluster. This may indicate an expired kubeconfig, network connectivity issues, or the cluster being unreachable.\n\nSTDOUT:\n${connectivity.stdout}\n\nSTDERR:\n${connectivity.stderr}
        ...    next_steps=Verify kubeconfig is valid and not expired\nCheck network connectivity to the cluster API server\nVerify the context '${CONTEXT}' is correctly configured\nCheck if the cluster is running and accessible
        BuiltIn.Fatal Error    Kubernetes cluster connectivity check failed for context '${CONTEXT}'. Aborting suite.
    END
