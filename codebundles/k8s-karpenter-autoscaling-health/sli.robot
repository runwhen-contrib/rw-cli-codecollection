*** Settings ***
Documentation       Measures Karpenter autoscaling health using NodePool or NodeClaim conditions, Pending capacity signals, and stuck NodeClaims. Produces a value between 0 and 1.
Metadata            Author    rw-codebundle-agent
Metadata            Display Name    Kubernetes Karpenter Autoscaling Health
Metadata            Supports    Kubernetes Karpenter EKS AKS GKE OpenShift

Force Tags          Kubernetes    Karpenter    autoscaling    health    sli

Library             BuiltIn
Library             Collections
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             OperatingSystem

Suite Setup         Suite Initialization


*** Tasks ***
Measure Karpenter Autoscaling Health Score for Cluster `${CONTEXT}`
    [Documentation]    Runs lightweight kubectl checks and averages binary dimension scores into a single 0 to 1 metric.
    [Tags]    access:read-only    data:config

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=sli-karpenter-autoscaling-score.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    timeout_seconds=120
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=CONTEXT="${CONTEXT}" ./sli-karpenter-autoscaling-score.sh

    TRY
        ${data}=    Evaluate    json.loads(r'''${result.stdout}''')    json
    EXCEPT
        Log    SLI JSON parse failed; scoring 0.    WARN
        ${data}=    Create Dictionary    d_nodepool=0    d_pending=0    d_stuck=0
    END

    ${d1}=    Get From Dictionary    ${data}    d_nodepool
    ${d2}=    Get From Dictionary    ${data}    d_pending
    ${d3}=    Get From Dictionary    ${data}    d_stuck
    RW.Core.Push Metric    ${d1}    sub_name=nodepool_nodeclaim_conditions
    RW.Core.Push Metric    ${d2}    sub_name=pending_capacity_signals
    RW.Core.Push Metric    ${d3}    sub_name=stuck_nodeclaims
    ${health_score}=    Evaluate    (${d1} + ${d2} + ${d3}) / 3
    ${health_score}=    Convert To Number    ${health_score}    2
    RW.Core.Push Metric    ${health_score}


*** Keywords ***
Suite Initialization
    ${kubeconfig}=    RW.Core.Import Secret
    ...    kubeconfig
    ...    type=string
    ...    description=Kubeconfig with read-only cluster access.
    ...    pattern=\w*
    ${CONTEXT}=    RW.Core.Import User Variable    CONTEXT
    ...    type=string
    ...    description=Kubernetes context name for the target cluster.
    ...    pattern=\w*
    ${KUBERNETES_DISTRIBUTION_BINARY}=    RW.Core.Import User Variable    KUBERNETES_DISTRIBUTION_BINARY
    ...    type=string
    ...    description=kubectl-compatible CLI binary.
    ...    enum=[kubectl,oc]
    ...    default=kubectl
    ${SLI_PENDING_POD_MAX}=    RW.Core.Import User Variable    SLI_PENDING_POD_MAX
    ...    type=string
    ...    description=Maximum Pending pods with capacity-like messages before SLI fails the pending dimension.
    ...    pattern=^\d+$
    ...    default=5
    ${STUCK_NODECLAIM_THRESHOLD_MINUTES}=    RW.Core.Import User Variable    STUCK_NODECLAIM_THRESHOLD_MINUTES
    ...    type=string
    ...    description=Same threshold as runbook stuck NodeClaim minutes for SLI scoring.
    ...    pattern=^\d+$
    ...    default=30
    Set Suite Variable    ${kubeconfig}    ${kubeconfig}
    Set Suite Variable    ${CONTEXT}    ${CONTEXT}
    Set Suite Variable    ${KUBERNETES_DISTRIBUTION_BINARY}    ${KUBERNETES_DISTRIBUTION_BINARY}
    Set Suite Variable    ${SLI_PENDING_POD_MAX}    ${SLI_PENDING_POD_MAX}
    Set Suite Variable    ${STUCK_NODECLAIM_THRESHOLD_MINUTES}    ${STUCK_NODECLAIM_THRESHOLD_MINUTES}
    ${env}=    Create Dictionary
    ...    KUBECONFIG=./${kubeconfig.key}
    ...    CONTEXT=${CONTEXT}
    ...    KUBERNETES_DISTRIBUTION_BINARY=${KUBERNETES_DISTRIBUTION_BINARY}
    ...    SLI_PENDING_POD_MAX=${SLI_PENDING_POD_MAX}
    ...    STUCK_NODECLAIM_THRESHOLD_MINUTES=${STUCK_NODECLAIM_THRESHOLD_MINUTES}
    Set Suite Variable    ${env}    ${env}
