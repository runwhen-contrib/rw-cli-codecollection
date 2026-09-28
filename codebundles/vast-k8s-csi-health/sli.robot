*** Settings ***
Documentation       Measures VAST CSI health by scoring CSI pod readiness, PVC binding, workload mounts, and NFS transport metrics. Produces a value between 0 (failing) and 1 (healthy).
Metadata            Author    rw-codebundle-agent
Metadata            Display Name    VAST Data Kubernetes CSI Health
Metadata            Supports    Kubernetes    VAST    CSI    NFS    storage

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
    ...    description=Kubernetes kubeconfig for cluster access.
    ...    pattern=\w*
    ${CONTEXT}=    RW.Core.Import User Variable    CONTEXT
    ...    type=string
    ...    description=Kubernetes context name.
    ...    pattern=\w*
    ${NAMESPACE}=    RW.Core.Import User Variable    NAMESPACE
    ...    type=string
    ...    description=Kubernetes namespace for workload PVC tracing.
    ...    pattern=\w*
    ${CSI_NAMESPACE}=    RW.Core.Import User Variable    CSI_NAMESPACE
    ...    type=string
    ...    description=Namespace where the VAST CSI driver is installed.
    ...    pattern=\w*
    ...    default=vast-csi
    ${KUBERNETES_DISTRIBUTION_BINARY}=    RW.Core.Import User Variable    KUBERNETES_DISTRIBUTION_BINARY
    ...    type=string
    ...    description=Kubernetes CLI binary (kubectl or oc).
    ...    enum=[kubectl,oc]
    ...    default=kubectl
    ${XPRT_PENDING_THRESHOLD}=    RW.Core.Import User Variable    XPRT_PENDING_THRESHOLD
    ...    type=string
    ...    description=csi_node_nfs_xprt_pending_requests count that triggers a failing NFS score.
    ...    pattern=^\d+$
    ...    default=100
    ${RPC_ERROR_RATE_THRESHOLD}=    RW.Core.Import User Variable    RPC_ERROR_RATE_THRESHOLD
    ...    type=string
    ...    description=CSI RPC error rate percent threshold (reserved for future SLI expansion).
    ...    pattern=^\d+$
    ...    default=5

    Set Suite Variable    ${kubeconfig}    ${kubeconfig}
    Set Suite Variable    ${CONTEXT}    ${CONTEXT}
    Set Suite Variable    ${NAMESPACE}    ${NAMESPACE}
    Set Suite Variable    ${CSI_NAMESPACE}    ${CSI_NAMESPACE}
    Set Suite Variable    ${KUBERNETES_DISTRIBUTION_BINARY}    ${KUBERNETES_DISTRIBUTION_BINARY}
    Set Suite Variable    ${XPRT_PENDING_THRESHOLD}    ${XPRT_PENDING_THRESHOLD}
    Set Suite Variable    ${RPC_ERROR_RATE_THRESHOLD}    ${RPC_ERROR_RATE_THRESHOLD}
    Set Suite Variable
    ...    ${env}
    ...    {"KUBECONFIG":"./${kubeconfig.key}","CONTEXT":"${CONTEXT}","NAMESPACE":"${NAMESPACE}","CSI_NAMESPACE":"${CSI_NAMESPACE}","KUBERNETES_DISTRIBUTION_BINARY":"${KUBERNETES_DISTRIBUTION_BINARY}","XPRT_PENDING_THRESHOLD":"${XPRT_PENDING_THRESHOLD}","RPC_ERROR_RATE_THRESHOLD":"${RPC_ERROR_RATE_THRESHOLD}"}


*** Tasks ***
Score VAST CSI Health Dimensions for Namespace `${NAMESPACE}`
    [Documentation]    Runs a compact probe returning binary scores for CSI pods, PVC binding, mounts, and NFS xprt health.
    [Tags]    access:read-only    data:metrics

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=sli-vast-csi-health-score.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    timeout_seconds=120
    ...    include_in_history=false
    ...    cmd_override=./sli-vast-csi-health-score.sh

    TRY
        ${dims}=    Evaluate    json.loads(r'''${result.stdout}''')    json
        ${csi}=    Get From Dictionary    ${dims}    csi_pods
        ${pvc}=    Get From Dictionary    ${dims}    pvc_bound
        ${mount}=    Get From Dictionary    ${dims}    mounts
        ${xprt}=    Get From Dictionary    ${dims}    nfs_xprt
        ${csi}=    Convert To Integer    ${csi}
        ${pvc}=    Convert To Integer    ${pvc}
        ${mount}=    Convert To Integer    ${mount}
        ${xprt}=    Convert To Integer    ${xprt}
    EXCEPT
        Log    SLI JSON parse failed; reporting zero health.    WARN
        ${csi}=    Convert To Integer    0
        ${pvc}=    Convert To Integer    0
        ${mount}=    Convert To Integer    0
        ${xprt}=    Convert To Integer    0
    END

    RW.Core.Push Metric    ${csi}    sub_name=csi_pods
    RW.Core.Push Metric    ${pvc}    sub_name=pvc_bound
    RW.Core.Push Metric    ${mount}    sub_name=mounts
    RW.Core.Push Metric    ${xprt}    sub_name=nfs_xprt

    ${health_score}=    Evaluate    (${csi} + ${pvc} + ${mount} + ${xprt}) / 4.0
    ${health_score}=    Convert to Number    ${health_score}    2
    RW.Core.Add to Report    Health Score: ${health_score}
    RW.Core.Push Metric    ${health_score}
