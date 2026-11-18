*** Settings ***
Documentation       Monitors the VAST CSI driver and traces Kubernetes workload storage from PVCs through to VAST views, detecting driver failures, NFS congestion, and mount issues.
Metadata            Author    rw-codebundle-agent
Metadata            Display Name    VAST Data Kubernetes CSI Health
Metadata            Supports    Kubernetes    VAST    CSI    NFS    storage    persistentvolumeclaim

Force Tags          Kubernetes    VAST    CSI    storage    health

Library             String
Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             RW.K8sHelper

Suite Setup         Suite Initialization


*** Tasks ***
Check VAST CSI Driver Pod Health in Namespace `${CSI_NAMESPACE}` on Cluster `${CONTEXT}`
    [Documentation]    Verifies CSI controller Deployment/StatefulSet and node DaemonSet pods are Running/Ready; checks for CrashLoopBackOff and recent restarts.
    [Tags]    Kubernetes    VAST    CSI    access:read-only    data:logs-config

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check-csi-pod-health.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=CONTEXT="${CONTEXT}" CSI_NAMESPACE="${CSI_NAMESPACE}" ./check-csi-pod-health.sh

    ${raw}=    RW.CLI.Run Cli
    ...    cmd=cat csi_pod_health_issues.json
    ...    env=${env}
    ...    include_in_history=false

    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${raw.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for CSI pod health task.    WARN
        ${issue_list}=    Create List
    END

    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=VAST CSI controller and node pods should be Ready in namespace `${CSI_NAMESPACE}`
            ...    actual=Unhealthy CSI pod signals detected on context `${CONTEXT}`
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END

    RW.Core.Add Pre To Report    VAST CSI pod health analysis:
    RW.Core.Add Pre To Report    ${result.stdout}

Check CSI Node and Controller Metrics for RPC Failures in Namespace `${CSI_NAMESPACE}`
    [Documentation]    Scrapes /metrics from CSI node and controller endpoints; detects elevated csi_plugin_operations failures and slow RPC durations.
    [Tags]    Kubernetes    VAST    CSI    metrics    access:read-only    data:metrics

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check-csi-metrics.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=CONTEXT="${CONTEXT}" CSI_NAMESPACE="${CSI_NAMESPACE}" RPC_ERROR_RATE_THRESHOLD="${RPC_ERROR_RATE_THRESHOLD}" ./check-csi-metrics.sh

    ${raw}=    RW.CLI.Run Cli
    ...    cmd=cat csi_metrics_issues.json
    ...    env=${env}
    ...    include_in_history=false

    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${raw.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for CSI metrics task.    WARN
        ${issue_list}=    Create List
    END

    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=CSI RPC error rates should remain below `${RPC_ERROR_RATE_THRESHOLD}` percent
            ...    actual=CSI metrics analysis reported issues in namespace `${CSI_NAMESPACE}`
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END

    RW.Core.Add Pre To Report    VAST CSI metrics analysis:
    RW.Core.Add Pre To Report    ${result.stdout}

Check NFS Transport Health on CSI Nodes in Namespace `${CSI_NAMESPACE}`
    [Documentation]    Analyzes csi_node_nfs_xprt metrics for network congestion and unhealthy VIP connections on CSI node pods.
    [Tags]    Kubernetes    VAST    NFS    metrics    access:read-only    data:metrics

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check-nfs-xprt-health.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    cmd_override=CONTEXT="${CONTEXT}" CSI_NAMESPACE="${CSI_NAMESPACE}" XPRT_PENDING_THRESHOLD="${XPRT_PENDING_THRESHOLD}" ./check-nfs-xprt-health.sh

    ${raw}=    RW.CLI.Run Cli
    ...    cmd=cat nfs_xprt_issues.json
    ...    env=${env}
    ...    include_in_history=false

    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${raw.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for NFS xprt task.    WARN
        ${issue_list}=    Create List
    END

    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=NFS transports to VAST VIPs should be healthy with pending requests below `${XPRT_PENDING_THRESHOLD}`
            ...    actual=NFS xprt congestion or unhealthy VIP signals detected on context `${CONTEXT}`
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END

    RW.Core.Add Pre To Report    NFS transport (xprt) analysis:
    RW.Core.Add Pre To Report    ${result.stdout}

Trace Kubernetes PVCs to VAST Views for Namespace `${NAMESPACE}`
    [Documentation]    Maps PVC to PV to StorageClass parameters and produces a trace report linking workload storage to VAST view, tenant, and VIP identifiers.
    [Tags]    Kubernetes    VAST    PVC    trace    access:read-only    data:config

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=trace-pvc-to-vast.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=CONTEXT="${CONTEXT}" NAMESPACE="${NAMESPACE}" ./trace-pvc-to-vast.sh

    ${raw}=    RW.CLI.Run Cli
    ...    cmd=cat pvc_trace_issues.json
    ...    env=${env}
    ...    include_in_history=false

    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${raw.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for PVC trace task.    WARN
        ${issue_list}=    Create List
    END

    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=VAST-backed PVCs in `${NAMESPACE}` should bind and expose traceable VAST identifiers
            ...    actual=PVC trace analysis completed for namespace `${NAMESPACE}`
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END

    RW.Core.Add Pre To Report    PVC to VAST trace report:
    RW.Core.Add Pre To Report    ${result.stdout}

Check End-to-End Pod Mount Health for VAST Storage in Namespace `${NAMESPACE}`
    [Documentation]    Identifies pods using VAST CSI volumes with mount failures, VolumeAttachment issues, or NodePublishVolume errors in events.
    [Tags]    Kubernetes    VAST    pod    mount    access:read-only    data:logs-config

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check-pod-mount-health.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    cmd_override=CONTEXT="${CONTEXT}" NAMESPACE="${NAMESPACE}" ./check-pod-mount-health.sh

    ${raw}=    RW.CLI.Run Cli
    ...    cmd=cat pod_mount_issues.json
    ...    env=${env}
    ...    include_in_history=false

    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${raw.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for pod mount health task.    WARN
        ${issue_list}=    Create List
    END

    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=Pods using VAST PVCs in `${NAMESPACE}` should mount successfully and reach Ready state
            ...    actual=Mount or attachment issues detected for VAST storage workloads
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END

    RW.Core.Add Pre To Report    Pod mount health analysis:
    RW.Core.Add Pre To Report    ${result.stdout}

Check VAST StorageClass Configuration for Cluster `${CONTEXT}`
    [Documentation]    Validates StorageClass parameters such as endpoint, view policy, mount options, and QoS settings for misconfigurations that limit workloads.
    [Tags]    Kubernetes    VAST    StorageClass    access:read-only    data:config

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check-vast-storageclass-config.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    cmd_override=CONTEXT="${CONTEXT}" ./check-vast-storageclass-config.sh

    ${raw}=    RW.CLI.Run Cli
    ...    cmd=cat storageclass_config_issues.json
    ...    env=${env}
    ...    include_in_history=false

    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${raw.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for StorageClass config task.    WARN
        ${issue_list}=    Create List
    END

    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=VAST StorageClasses should define endpoint, view policy, and tenant parameters correctly
            ...    actual=StorageClass configuration review found gaps on context `${CONTEXT}`
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END

    RW.Core.Add Pre To Report    VAST StorageClass configuration review:
    RW.Core.Add Pre To Report    ${result.stdout}

Correlate Kubernetes Storage Events with VAST Tenant Metrics for Namespace `${NAMESPACE}`
    [Documentation]    When VAST_VMS_ENDPOINT is configured, cross-references failing PVCs with tenant capacity and QoS metrics from VMS to distinguish driver vs backend issues.
    [Tags]    Kubernetes    VAST    VMS    correlation    access:read-only    data:metrics

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=correlate-k8s-vast-events.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    secret__vast_vms_credentials=${VMS_CREDENTIALS}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    cmd_override=CONTEXT="${CONTEXT}" NAMESPACE="${NAMESPACE}" VAST_VMS_ENDPOINT="${VAST_VMS_ENDPOINT}" ./correlate-k8s-vast-events.sh

    ${raw}=    RW.CLI.Run Cli
    ...    cmd=cat vast_correlation_issues.json
    ...    env=${env}
    ...    include_in_history=false

    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${raw.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for VMS correlation task.    WARN
        ${issue_list}=    Create List
    END

    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=Kubernetes storage symptoms should be explainable by VMS tenant health when backend correlation is enabled
            ...    actual=VMS correlation analysis completed for namespace `${NAMESPACE}`
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END

    RW.Core.Add Pre To Report    Kubernetes/VMS correlation results:
    RW.Core.Add Pre To Report    ${result.stdout}


*** Keywords ***
Suite Initialization
    ${kubeconfig}=    RW.Core.Import Secret
    ...    kubeconfig
    ...    type=string
    ...    description=Kubernetes kubeconfig for cluster access.
    ...    pattern=\w*

    TRY
        ${vms_credentials}=    RW.Core.Import Secret
        ...    vast_vms_credentials
        ...    type=string
        ...    description=Optional VMS credentials JSON with USERNAME, PASSWORD or API_TOKEN.
        ...    pattern=\w*
        Set Suite Variable    ${VMS_CREDENTIALS}    ${vms_credentials}
    EXCEPT
        Log    vast_vms_credentials not found; VMS correlation will skip unless endpoint allows anonymous access.    WARN
        Set Suite Variable    ${VMS_CREDENTIALS}    ${EMPTY}
    END

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
    ${VAST_VMS_ENDPOINT}=    RW.Core.Import User Variable    VAST_VMS_ENDPOINT
    ...    type=string
    ...    description=Optional VMS endpoint for backend correlation task.
    ...    pattern=.*
    ...    default=
    ${VAST_CLUSTER_NAME}=    RW.Core.Import User Variable    VAST_CLUSTER_NAME
    ...    type=string
    ...    description=Optional VAST cluster name for correlation task titles.
    ...    pattern=.*
    ...    default=
    ${XPRT_PENDING_THRESHOLD}=    RW.Core.Import User Variable    XPRT_PENDING_THRESHOLD
    ...    type=string
    ...    description=csi_node_nfs_xprt_pending_requests count that triggers an issue.
    ...    pattern=^\d+$
    ...    default=100
    ${RPC_ERROR_RATE_THRESHOLD}=    RW.Core.Import User Variable    RPC_ERROR_RATE_THRESHOLD
    ...    type=string
    ...    description=CSI RPC error rate percent threshold.
    ...    pattern=^\d+$
    ...    default=5

    Set Suite Variable    ${kubeconfig}    ${kubeconfig}
    Set Suite Variable    ${CONTEXT}    ${CONTEXT}
    Set Suite Variable    ${NAMESPACE}    ${NAMESPACE}
    Set Suite Variable    ${CSI_NAMESPACE}    ${CSI_NAMESPACE}
    Set Suite Variable    ${KUBERNETES_DISTRIBUTION_BINARY}    ${KUBERNETES_DISTRIBUTION_BINARY}
    Set Suite Variable    ${VAST_VMS_ENDPOINT}    ${VAST_VMS_ENDPOINT}
    Set Suite Variable    ${VAST_CLUSTER_NAME}    ${VAST_CLUSTER_NAME}
    Set Suite Variable    ${XPRT_PENDING_THRESHOLD}    ${XPRT_PENDING_THRESHOLD}
    Set Suite Variable    ${RPC_ERROR_RATE_THRESHOLD}    ${RPC_ERROR_RATE_THRESHOLD}

    Set Suite Variable
    ...    ${env}
    ...    {"KUBECONFIG":"./${kubeconfig.key}","CONTEXT":"${CONTEXT}","NAMESPACE":"${NAMESPACE}","CSI_NAMESPACE":"${CSI_NAMESPACE}","KUBERNETES_DISTRIBUTION_BINARY":"${KUBERNETES_DISTRIBUTION_BINARY}","VAST_VMS_ENDPOINT":"${VAST_VMS_ENDPOINT}","VAST_CLUSTER_NAME":"${VAST_CLUSTER_NAME}","XPRT_PENDING_THRESHOLD":"${XPRT_PENDING_THRESHOLD}","RPC_ERROR_RATE_THRESHOLD":"${RPC_ERROR_RATE_THRESHOLD}"}

    RW.K8sHelper.Verify Cluster Connectivity
    ...    binary=${KUBERNETES_DISTRIBUTION_BINARY}
    ...    context=${CONTEXT}
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
