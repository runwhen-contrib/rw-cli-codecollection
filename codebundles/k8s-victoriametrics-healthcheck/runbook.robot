*** Settings ***
Documentation       Validates VictoriaMetrics workloads on Kubernetes: pod readiness, PVC health, HTTP /health probes, vmselect cluster status when applicable, and recent error logs.
Metadata            Author    rw-codebundle-agent
Metadata            Display Name    Kubernetes VictoriaMetrics Health Check
Metadata            Supports    Kubernetes AKS EKS GKE OpenShift VictoriaMetrics

Force Tags          Kubernetes    VictoriaMetrics    Health    Namespace

Library             String
Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             RW.K8sHelper

Suite Setup         Suite Initialization


*** Tasks ***
Verify VictoriaMetrics Workload Pod Readiness for Namespace `${NAMESPACE}`
    [Documentation]    Lists Deployments, StatefulSets, and DaemonSets scoped to VictoriaMetrics labels and reports pods not Ready, CrashLoopBackOff, ImagePullBackOff, or failed rollout conditions.
    [Tags]    Kubernetes    VictoriaMetrics    access:read-only    data:logs-config

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check-vm-workload-readiness.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./check-vm-workload-readiness.sh

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat vm_workload_readiness_issues.json
    ...    env=${env}
    ...    include_in_history=false

    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for workload readiness task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END

    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=VictoriaMetrics workloads in `${NAMESPACE}` should have healthy pods and rollouts
            ...    actual=Unhealthy workload or pod state detected for VictoriaMetrics components
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END

    RW.Core.Add Pre To Report    VictoriaMetrics workload readiness analysis:\n${result.stdout}

Check VictoriaMetrics Storage PVCs in Namespace `${NAMESPACE}`
    [Documentation]    Lists PVCs associated with VictoriaMetrics storage (especially vmstorage) and flags Pending, Failed, Lost, or binding problems.
    [Tags]    Kubernetes    VictoriaMetrics    storage    access:read-only    data:logs-config

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check-vm-storage-pvcs.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=false
    ...    cmd_override=./check-vm-storage-pvcs.sh

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat vm_storage_pvc_issues.json
    ...    env=${env}
    ...    include_in_history=false

    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for PVC task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END

    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=VictoriaMetrics PVCs in `${NAMESPACE}` should be Bound and healthy
            ...    actual=Storage claim issue detected for VictoriaMetrics workloads
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END

    RW.Core.Add Pre To Report    VictoriaMetrics PVC analysis:\n${result.stdout}

Probe VictoriaMetrics HTTP Health Endpoints in Namespace `${NAMESPACE}`
    [Documentation]    For each running VictoriaMetrics component pod, curls localhost /health via kubectl exec using default ports per component (single, vmselect, vminsert, vmstorage, vmagent).
    [Tags]    Kubernetes    VictoriaMetrics    access:read-only    data:metrics

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check-vm-http-health.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    timeout_seconds=240
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=false
    ...    cmd_override=./check-vm-http-health.sh

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat vm_http_health_issues.json
    ...    env=${env}
    ...    include_in_history=false

    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for HTTP health task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END

    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=VictoriaMetrics `/health` endpoints should respond successfully inside each component pod
            ...    actual=HTTP health check failed or returned unexpected body for a VictoriaMetrics pod
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END

    RW.Core.Add Pre To Report    VictoriaMetrics HTTP health probes:\n${result.stdout}

Check VictoriaMetrics Cluster Status API for vmselect in Namespace `${NAMESPACE}`
    [Documentation]    When cluster mode is active, requests vmselect cluster status JSON and flags degraded storage or unreachable status APIs.
    [Tags]    Kubernetes    VictoriaMetrics    cluster    access:read-only    data:metrics

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check-vm-cluster-status.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=false
    ...    cmd_override=./check-vm-cluster-status.sh

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat vm_cluster_status_issues.json
    ...    env=${env}
    ...    include_in_history=false

    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for cluster status task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END

    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=vmselect cluster status should report healthy storage connectivity
            ...    actual=Cluster status check reported a problem or could not query the API
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END

    RW.Core.Add Pre To Report    VictoriaMetrics cluster status:\n${result.stdout}

Scan VictoriaMetrics Recent Logs for Errors in Namespace `${NAMESPACE}`
    [Documentation]    Greps recent container logs on VictoriaMetrics pods for ERROR, panic, or fatal patterns to catch runtime failures not visible from phase alone.
    [Tags]    Kubernetes    VictoriaMetrics    logs    access:read-only    data:logs-regexp

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check-vm-recent-error-logs.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    timeout_seconds=300
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=false
    ...    cmd_override=./check-vm-recent-error-logs.sh

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat vm_recent_error_logs_issues.json
    ...    env=${env}
    ...    include_in_history=false

    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for log scan task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END

    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=VictoriaMetrics logs should be free of repeated ERROR, panic, or fatal lines under normal operation
            ...    actual=Error signature lines found in recent VictoriaMetrics container logs
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END

    RW.Core.Add Pre To Report    VictoriaMetrics log scan:\n${result.stdout}


*** Keywords ***
Suite Initialization
    ${kubeconfig}=    RW.Core.Import Secret
    ...    kubeconfig
    ...    type=string
    ...    description=The kubernetes kubeconfig yaml containing connection configuration used to connect to cluster(s).
    ...    pattern=\w*
    ${KUBERNETES_DISTRIBUTION_BINARY}=    RW.Core.Import User Variable    KUBERNETES_DISTRIBUTION_BINARY
    ...    type=string
    ...    description=Which binary to use for Kubernetes CLI commands.
    ...    enum=[kubectl,oc]
    ...    default=kubectl
    ${CONTEXT}=    RW.Core.Import User Variable    CONTEXT
    ...    type=string
    ...    description=Kubernetes context to use.
    ...    pattern=\w*
    ${NAMESPACE}=    RW.Core.Import User Variable    NAMESPACE
    ...    type=string
    ...    description=Namespace where VictoriaMetrics workloads run.
    ...    pattern=\w*
    ${VM_LABEL_SELECTOR}=    RW.Core.Import User Variable    VM_LABEL_SELECTOR
    ...    type=string
    ...    description=Optional label selector to scope pods (e.g. app.kubernetes.io/instance=my-vm).
    ...    pattern=.*
    ...    default=${EMPTY}
    ${VM_DEPLOYMENT_MODE}=    RW.Core.Import User Variable    VM_DEPLOYMENT_MODE
    ...    type=string
    ...    description=single, cluster, or auto (detect vmselect vs single-node).
    ...    pattern=\w*
    ...    default=auto
    Set Suite Variable    ${kubeconfig}    ${kubeconfig}
    Set Suite Variable    ${KUBERNETES_DISTRIBUTION_BINARY}    ${KUBERNETES_DISTRIBUTION_BINARY}
    Set Suite Variable    ${CONTEXT}    ${CONTEXT}
    Set Suite Variable    ${NAMESPACE}    ${NAMESPACE}
    Set Suite Variable    ${VM_LABEL_SELECTOR}    ${VM_LABEL_SELECTOR}
    Set Suite Variable    ${VM_DEPLOYMENT_MODE}    ${VM_DEPLOYMENT_MODE}
    Set Suite Variable    ${env}    {"KUBECONFIG":"./${kubeconfig.key}", "KUBERNETES_DISTRIBUTION_BINARY":"${KUBERNETES_DISTRIBUTION_BINARY}", "CONTEXT":"${CONTEXT}", "NAMESPACE":"${NAMESPACE}", "VM_LABEL_SELECTOR":"${VM_LABEL_SELECTOR}", "VM_DEPLOYMENT_MODE":"${VM_DEPLOYMENT_MODE}"}

    RW.K8sHelper.Verify Cluster Connectivity
    ...    binary=${KUBERNETES_DISTRIBUTION_BINARY}
    ...    context=${CONTEXT}
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
