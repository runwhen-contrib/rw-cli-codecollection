*** Settings ***
Documentation       Measures Karpenter control-plane health using lightweight controller readiness, webhook presence, warning event volume, and Service endpoint checks. Produces a value between 0 (failing) and 1 (healthy).
Metadata            Author    rw-codebundle-agent
Metadata            Display Name    Kubernetes Karpenter Control Plane Health
Metadata            Supports    Kubernetes Karpenter cluster control-plane health

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             Collections

Suite Setup         Suite Initialization


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
    ${KARPENTER_NAMESPACE}=    RW.Core.Import User Variable    KARPENTER_NAMESPACE
    ...    type=string
    ...    description=Namespace where the Karpenter controller runs.
    ...    pattern=\w*
    ...    default=karpenter
    ${KUBERNETES_DISTRIBUTION_BINARY}=    RW.Core.Import User Variable    KUBERNETES_DISTRIBUTION_BINARY
    ...    type=string
    ...    description=kubectl-compatible CLI binary.
    ...    enum=[kubectl,oc]
    ...    default=kubectl
    ${RW_LOOKBACK_WINDOW}=    RW.Core.Import User Variable    RW_LOOKBACK_WINDOW
    ...    type=string
    ...    description=Lookback window for warning event counts in the SLI.
    ...    pattern=\w*
    ...    default=30m
    ${SLI_WARNING_EVENT_THRESHOLD}=    RW.Core.Import User Variable    SLI_WARNING_EVENT_THRESHOLD
    ...    type=string
    ...    description=Maximum Warning events allowed in the lookback window for a passing score.
    ...    pattern=^\d+$
    ...    default=5
    Set Suite Variable    ${kubeconfig}    ${kubeconfig}
    Set Suite Variable    ${CONTEXT}    ${CONTEXT}
    Set Suite Variable    ${KARPENTER_NAMESPACE}    ${KARPENTER_NAMESPACE}
    Set Suite Variable    ${KUBERNETES_DISTRIBUTION_BINARY}    ${KUBERNETES_DISTRIBUTION_BINARY}
    Set Suite Variable    ${RW_LOOKBACK_WINDOW}    ${RW_LOOKBACK_WINDOW}
    Set Suite Variable    ${SLI_WARNING_EVENT_THRESHOLD}    ${SLI_WARNING_EVENT_THRESHOLD}
    Set Suite Variable
    ...    ${env}
    ...    {"KUBECONFIG":"./${kubeconfig.key}","CONTEXT":"${CONTEXT}","KARPENTER_NAMESPACE":"${KARPENTER_NAMESPACE}","KUBERNETES_DISTRIBUTION_BINARY":"${KUBERNETES_DISTRIBUTION_BINARY}","RW_LOOKBACK_WINDOW":"${RW_LOOKBACK_WINDOW}","SLI_WARNING_EVENT_THRESHOLD":"${SLI_WARNING_EVENT_THRESHOLD}"}


*** Tasks ***
Score Karpenter Control Plane Dimensions in Cluster `${CONTEXT}`
    [Documentation]    Runs a compact bash probe that returns binary scores per dimension and aggregates them into the SLI metric.
    [Tags]    access:read-only    data:config

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=sli-karpenter-dimensions.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    timeout_seconds=120
    ...    include_in_history=false
    ...    cmd_override=./sli-karpenter-dimensions.sh

    TRY
        ${dims}=    Evaluate    json.loads(r'''${result.stdout}''')    json
        ${c}=    Get From Dictionary    ${dims}    controller
        ${w}=    Get From Dictionary    ${dims}    webhook
        ${e}=    Get From Dictionary    ${dims}    warnings
        ${s}=    Get From Dictionary    ${dims}    service
        ${c}=    Convert To Integer    ${c}
        ${w}=    Convert To Integer    ${w}
        ${e}=    Convert To Integer    ${e}
        ${s}=    Convert To Integer    ${s}
    EXCEPT
        Log    SLI JSON parse failed; reporting zero health.    WARN
        ${c}=    Convert To Integer    0
        ${w}=    Convert To Integer    0
        ${e}=    Convert To Integer    0
        ${s}=    Convert To Integer    0
    END

    RW.Core.Push Metric    ${c}    sub_name=controller
    RW.Core.Push Metric    ${w}    sub_name=webhook
    RW.Core.Push Metric    ${e}    sub_name=warnings
    RW.Core.Push Metric    ${s}    sub_name=service

    ${health_score}=    Evaluate    (${c} + ${w} + ${e} + ${s}) / 4.0
    ${health_score}=    Convert to Number    ${health_score}    2
    RW.Core.Add to Report    Karpenter control-plane health score: ${health_score} (controller=${c}, webhook=${w}, warnings=${e}, service=${s})
    RW.Core.Push Metric    ${health_score}
