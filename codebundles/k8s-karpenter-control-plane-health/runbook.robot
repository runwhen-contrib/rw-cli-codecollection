*** Settings ***
Documentation       Monitors Karpenter controller health: workload readiness, admission webhooks, warning events, CRD versions, and metrics Service wiring before investigating provisioning behavior.
Metadata            Author    rw-codebundle-agent
Metadata            Display Name    Kubernetes Karpenter Control Plane Health
Metadata            Supports    Kubernetes Karpenter cluster control-plane health

Library             String
Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             RW.K8sHelper

Force Tags          Kubernetes    Karpenter    health    control-plane

Suite Setup         Suite Initialization


*** Tasks ***
Check Karpenter Controller Workload Health in Cluster `${CONTEXT}`
    [Documentation]    Verifies Karpenter controller pods are Ready, surfaces CrashLoopBackOff, high restarts, and replica gaps for Karpenter Deployments.
    [Tags]    Kubernetes    Karpenter    access:read-only    data:config

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check-karpenter-controller-pods.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=CONTEXT="${CONTEXT}" KARPENTER_NAMESPACE="${KARPENTER_NAMESPACE}" ./check-karpenter-controller-pods.sh

    ${raw}=    RW.CLI.Run Cli
    ...    cmd=cat controller_pods_issues.json
    ...    env=${env}
    ...    include_in_history=false

    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${raw.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for controller pod task.    WARN
        ${issue_list}=    Create List
    END

    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=Karpenter controller pods should be Ready with stable restarts in `${KARPENTER_NAMESPACE}`
            ...    actual=Unhealthy controller signals were detected for context `${CONTEXT}`
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END

    RW.Core.Add Pre To Report    Karpenter controller pod analysis (stdout):
    RW.Core.Add Pre To Report    ${result.stdout}

Verify Karpenter Admission Webhooks in Cluster `${CONTEXT}`
    [Documentation]    Lists ValidatingWebhookConfiguration and MutatingWebhookConfiguration objects tied to Karpenter and checks TLS client configuration and recent webhook-related warnings.
    [Tags]    Kubernetes    Karpenter    webhooks    access:read-only    data:config

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check-karpenter-webhooks.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    cmd_override=CONTEXT="${CONTEXT}" KARPENTER_NAMESPACE="${KARPENTER_NAMESPACE}" ./check-karpenter-webhooks.sh

    ${raw}=    RW.CLI.Run Cli
    ...    cmd=cat webhook_issues.json
    ...    env=${env}
    ...    include_in_history=false

    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${raw.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for webhook task.    WARN
        ${issue_list}=    Create List
    END

    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=Karpenter admission webhooks should be configured with valid endpoints and TLS material
            ...    actual=Potential misconfiguration detected for context `${CONTEXT}`
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END

    RW.Core.Add Pre To Report    Karpenter webhook checks (stdout):
    RW.Core.Add Pre To Report    ${result.stdout}

Inspect Warning Events in Karpenter Namespace `${KARPENTER_NAMESPACE}`
    [Documentation]    Aggregates recent Warning events involving Karpenter workloads or messages, grouped by involved object for triage.
    [Tags]    Kubernetes    Karpenter    events    access:read-only    data:events

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=karpenter-namespace-warning-events.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    cmd_override=CONTEXT="${CONTEXT}" KARPENTER_NAMESPACE="${KARPENTER_NAMESPACE}" RW_LOOKBACK_WINDOW="${RW_LOOKBACK_WINDOW}" ./karpenter-namespace-warning-events.sh

    ${raw}=    RW.CLI.Run Cli
    ...    cmd=cat warning_events_issues.json
    ...    env=${env}
    ...    include_in_history=false

    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${raw.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for warning events task.    WARN
        ${issue_list}=    Create List
    END

    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=No unexpected Warning events in `${KARPENTER_NAMESPACE}` during `${RW_LOOKBACK_WINDOW}`
            ...    actual=Warning events were observed for context `${CONTEXT}`
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END

    RW.Core.Add Pre To Report    Karpenter namespace warning events (stdout):
    RW.Core.Add Pre To Report    ${result.stdout}

Summarize Installed Karpenter API Versions and CRDs in Cluster `${CONTEXT}`
    [Documentation]    Detects CRD API groups related to Karpenter to spot missing installs or mixed API families.
    [Tags]    Kubernetes    Karpenter    crd    access:read-only    data:config

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check-karpenter-crds.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    cmd_override=CONTEXT="${CONTEXT}" ./check-karpenter-crds.sh

    ${raw}=    RW.CLI.Run Cli
    ...    cmd=cat crds_issues.json
    ...    env=${env}
    ...    include_in_history=false

    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${raw.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for CRD task.    WARN
        ${issue_list}=    Create List
    END

    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=Karpenter CRDs should be installed once with a consistent API group set
            ...    actual=CRD discovery found issues for context `${CONTEXT}`
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END

    RW.Core.Add Pre To Report    Karpenter CRD summary (stdout):
    RW.Core.Add Pre To Report    ${result.stdout}

Check Karpenter Service and Metrics Endpoints in Namespace `${KARPENTER_NAMESPACE}`
    [Documentation]    Validates Services that front the controller expose ports suitable for metrics scraping and that Endpoints are populated.
    [Tags]    Kubernetes    Karpenter    metrics    access:read-only    data:metrics

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check-karpenter-service-metrics.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    cmd_override=CONTEXT="${CONTEXT}" KARPENTER_NAMESPACE="${KARPENTER_NAMESPACE}" ./check-karpenter-service-metrics.sh

    ${raw}=    RW.CLI.Run Cli
    ...    cmd=cat service_metrics_issues.json
    ...    env=${env}
    ...    include_in_history=false

    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${raw.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for service metrics task.    WARN
        ${issue_list}=    Create List
    END

    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=Karpenter Services should have endpoints and metrics-friendly ports for observability
            ...    actual=Service or endpoint gaps detected in `${KARPENTER_NAMESPACE}` on `${CONTEXT}`
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END

    RW.Core.Add Pre To Report    Karpenter service and metrics review (stdout):
    RW.Core.Add Pre To Report    ${result.stdout}


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
    ...    description=Lookback window for event analysis (for example 30m or 2h).
    ...    pattern=\w*
    ...    default=30m
    Set Suite Variable    ${kubeconfig}    ${kubeconfig}
    Set Suite Variable    ${CONTEXT}    ${CONTEXT}
    Set Suite Variable    ${KARPENTER_NAMESPACE}    ${KARPENTER_NAMESPACE}
    Set Suite Variable    ${KUBERNETES_DISTRIBUTION_BINARY}    ${KUBERNETES_DISTRIBUTION_BINARY}
    Set Suite Variable    ${RW_LOOKBACK_WINDOW}    ${RW_LOOKBACK_WINDOW}
    Set Suite Variable
    ...    ${env}
    ...    {"KUBECONFIG":"./${kubeconfig.key}","CONTEXT":"${CONTEXT}","KARPENTER_NAMESPACE":"${KARPENTER_NAMESPACE}","KUBERNETES_DISTRIBUTION_BINARY":"${KUBERNETES_DISTRIBUTION_BINARY}","RW_LOOKBACK_WINDOW":"${RW_LOOKBACK_WINDOW}"}

    RW.K8sHelper.Verify Cluster Connectivity
    ...    binary=${KUBERNETES_DISTRIBUTION_BINARY}
    ...    context=${CONTEXT}
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
