*** Settings ***
Documentation       Monitors Karpenter-driven autoscaling: NodePools, NodeClaims, pending workloads, controller logs, and cloud NodeClasses.
Metadata            Author    rw-codebundle-agent
Metadata            Display Name    Kubernetes Karpenter Autoscaling Health
Metadata            Supports    Kubernetes Karpenter Autoscaling NodePool NodeClaim EKS AKS GKE

Force Tags          Kubernetes    Karpenter    autoscaling    health

Library             String
Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             RW.K8sHelper

Suite Setup         Suite Initialization


*** Tasks ***
Summarize NodePool and NodeClaim Health in Cluster `${CONTEXT}`
    [Documentation]    Lists NodePools or Provisioners and NodeClaims or Machines, parses unhealthy status conditions, and summarizes not-ready or cordoned nodes.
    [Tags]    Kubernetes    Karpenter    NodePool    NodeClaim    access:read-only    data:config

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check-karpenter-nodepool-nodeclaim-status.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=CONTEXT="${CONTEXT}" ./check-karpenter-nodepool-nodeclaim-status.sh

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat karpenter_nodepool_nodeclaim_issues.json
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}

    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END

    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=NodePools, NodeClaims, and nodes should be Ready with healthy conditions for context ${CONTEXT}.
            ...    actual=Unhealthy Karpenter or node conditions were detected.
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END

    RW.Core.Add Pre To Report    NodePool / NodeClaim summary:\n${result.stdout}

Detect Workloads Blocked on Provisioning or Capacity in Cluster `${CONTEXT}`
    [Documentation]    Finds Pending pods whose status messages indicate insufficient capacity, scheduling failures, or topology spread constraints correlated with scaling pressure.
    [Tags]    Kubernetes    Karpenter    Pending    scheduling    access:read-only    data:config

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check-pending-provisioning-workloads.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=CONTEXT="${CONTEXT}" ./check-pending-provisioning-workloads.sh

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat karpenter_pending_workload_issues.json
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}

    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END

    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=Workloads should schedule without prolonged Pending capacity errors in ${CONTEXT}.
            ...    actual=Pending pods show provisioning or capacity-related scheduling messages.
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END

    RW.Core.Add Pre To Report    Pending workload analysis:\n${result.stdout}

Scan Karpenter Controller Logs for Errors in Namespace `${KARPENTER_NAMESPACE}`
    [Documentation]    Aggregates recent controller pod logs for ERROR, WARN, and known failure substrings within RW_LOOKBACK_WINDOW, capped for RBAC and volume safety.
    [Tags]    Kubernetes    Karpenter    logs    controller    access:read-only    data:logs

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=scan-karpenter-controller-logs.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=CONTEXT="${CONTEXT}" KARPENTER_NAMESPACE="${KARPENTER_NAMESPACE}" ./scan-karpenter-controller-logs.sh

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat karpenter_controller_log_issues.json
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}

    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END

    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=Karpenter controller logs should be free of sustained errors for ${KARPENTER_NAMESPACE}.
            ...    actual=Matching error or warning log patterns exceeded the configured threshold.
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END

    RW.Core.Add Pre To Report    Controller log scan:\n${result.stdout}

Check Cloud NodeClass Resources for Misconfiguration Signals in Cluster `${CONTEXT}`
    [Documentation]    Reads EC2NodeClass, legacy AWSNodeTemplate, or other provider NodeClass conditions for subnet, security group, AMI, or IAM-related failures.
    [Tags]    Kubernetes    Karpenter    NodeClass    AWS    access:read-only    data:config

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check-karpenter-nodeclass-conditions.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=CONTEXT="${CONTEXT}" ./check-karpenter-nodeclass-conditions.sh

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat karpenter_nodeclass_issues.json
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}

    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END

    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=NodeClass objects should report Ready conditions without validation errors.
            ...    actual=A NodeClass or template reported False or Unknown conditions, or no CRDs were found.
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END

    RW.Core.Add Pre To Report    NodeClass condition scan:\n${result.stdout}

Identify Stale or Stuck NodeClaims in Cluster `${CONTEXT}`
    [Documentation]    Finds NodeClaims that remain non-ready past STUCK_NODECLAIM_THRESHOLD_MINUTES or show prolonged deletion, indicating consolidation or lifecycle issues.
    [Tags]    Kubernetes    Karpenter    NodeClaim    stuck    access:read-only    data:config

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check-stuck-nodeclaims.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=CONTEXT="${CONTEXT}" ./check-stuck-nodeclaims.sh

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat karpenter_stuck_nodeclaim_issues.json
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}

    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END

    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=NodeClaims should reach Ready and terminate cleanly within normal time bounds.
            ...    actual=Stale or stuck NodeClaims (or legacy Machines) were detected.
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END

    RW.Core.Add Pre To Report    Stuck NodeClaim analysis:\n${result.stdout}

Correlate Recent Karpenter Log Patterns with Pending Pods in Cluster `${CONTEXT}`
    [Documentation]    Optional cross-check that links controller log lines to Pending pod names when both appear together for faster triage.
    [Tags]    Kubernetes    Karpenter    correlation    logs    access:read-only    data:logs

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=correlate-karpenter-logs-pending-pods.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=CONTEXT="${CONTEXT}" KARPENTER_NAMESPACE="${KARPENTER_NAMESPACE}" ./correlate-karpenter-logs-pending-pods.sh

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat karpenter_correlation_issues.json
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}

    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END

    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=Controller logs should not repeatedly reference Pending workloads unless actively reconciling.
            ...    actual=Log lines matched error patterns and referenced a Pending pod name.
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END

    RW.Core.Add Pre To Report    Correlation results:\n${result.stdout}


*** Keywords ***
Suite Initialization
    ${kubeconfig}=    RW.Core.Import Secret
    ...    kubeconfig
    ...    type=string
    ...    description=Kubeconfig with read-only cluster access (pod logs require get logs permission).
    ...    pattern=\w*
    ${CONTEXT}=    RW.Core.Import User Variable    CONTEXT
    ...    type=string
    ...    description=Kubernetes context name for the target cluster.
    ...    pattern=\w*
    ${KARPENTER_NAMESPACE}=    RW.Core.Import User Variable    KARPENTER_NAMESPACE
    ...    type=string
    ...    description=Namespace where the Karpenter controller runs (for log tasks).
    ...    pattern=\w*
    ...    default=karpenter
    ${KUBERNETES_DISTRIBUTION_BINARY}=    RW.Core.Import User Variable    KUBERNETES_DISTRIBUTION_BINARY
    ...    type=string
    ...    description=kubectl-compatible CLI binary.
    ...    enum=[kubectl,oc]
    ...    default=kubectl
    ${RW_LOOKBACK_WINDOW}=    RW.Core.Import User Variable    RW_LOOKBACK_WINDOW
    ...    type=string
    ...    description=Lookback window for logs and recent transitions.
    ...    pattern=\w*
    ...    default=30m
    ${KARPENTER_LOG_ERROR_THRESHOLD}=    RW.Core.Import User Variable    KARPENTER_LOG_ERROR_THRESHOLD
    ...    type=string
    ...    description=Minimum matching controller log lines before raising an issue.
    ...    pattern=^\d+$
    ...    default=1
    ${STUCK_NODECLAIM_THRESHOLD_MINUTES}=    RW.Core.Import User Variable    STUCK_NODECLAIM_THRESHOLD_MINUTES
    ...    type=string
    ...    description=Minutes after which a non-ready NodeClaim is considered stale.
    ...    pattern=^\d+$
    ...    default=30
    ${KARPENTER_LOG_MAX_LINES}=    RW.Core.Import User Variable    KARPENTER_LOG_MAX_LINES
    ...    type=string
    ...    description=Maximum tail lines per controller pod for log tasks.
    ...    pattern=^\d+$
    ...    default=500
    Set Suite Variable    ${kubeconfig}    ${kubeconfig}
    Set Suite Variable    ${CONTEXT}    ${CONTEXT}
    Set Suite Variable    ${KARPENTER_NAMESPACE}    ${KARPENTER_NAMESPACE}
    Set Suite Variable    ${KUBERNETES_DISTRIBUTION_BINARY}    ${KUBERNETES_DISTRIBUTION_BINARY}
    Set Suite Variable    ${RW_LOOKBACK_WINDOW}    ${RW_LOOKBACK_WINDOW}
    Set Suite Variable    ${KARPENTER_LOG_ERROR_THRESHOLD}    ${KARPENTER_LOG_ERROR_THRESHOLD}
    Set Suite Variable    ${STUCK_NODECLAIM_THRESHOLD_MINUTES}    ${STUCK_NODECLAIM_THRESHOLD_MINUTES}
    Set Suite Variable    ${KARPENTER_LOG_MAX_LINES}    ${KARPENTER_LOG_MAX_LINES}
    ${env}=    Create Dictionary
    ...    KUBECONFIG=./${kubeconfig.key}
    ...    CONTEXT=${CONTEXT}
    ...    KARPENTER_NAMESPACE=${KARPENTER_NAMESPACE}
    ...    KUBERNETES_DISTRIBUTION_BINARY=${KUBERNETES_DISTRIBUTION_BINARY}
    ...    RW_LOOKBACK_WINDOW=${RW_LOOKBACK_WINDOW}
    ...    KARPENTER_LOG_ERROR_THRESHOLD=${KARPENTER_LOG_ERROR_THRESHOLD}
    ...    STUCK_NODECLAIM_THRESHOLD_MINUTES=${STUCK_NODECLAIM_THRESHOLD_MINUTES}
    ...    KARPENTER_LOG_MAX_LINES=${KARPENTER_LOG_MAX_LINES}
    Set Suite Variable    ${env}    ${env}
    RW.K8sHelper.Verify Cluster Connectivity
    ...    binary=${KUBERNETES_DISTRIBUTION_BINARY}
    ...    context=${CONTEXT}
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
