*** Settings ***
Documentation       Read-only diagnostics for Kubernetes Deployments whose rolling updates are stuck, slow, or failing.
Metadata            Author    rw-codebundle-agent
Metadata            Display Name    Kubernetes Deployment Rollout Troubleshoot
Metadata            Supports    Kubernetes    Deployment    Rollout    Troubleshoot    ReadOnly
Force Tags          Kubernetes    Deployment    Rollout    Troubleshoot

Library             String
Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform

Suite Setup         Suite Initialization


*** Tasks ***
Check Deployment Rollout Status for `${DEPLOYMENT_NAME}` in Namespace `${NAMESPACE}`
    [Documentation]    Evaluates rollout progress via deployment status fields and kubectl rollout status, detecting ProgressDeadlineExceeded and replica count mismatches.
    [Tags]    Kubernetes    Deployment    Rollout    Status    access:read-only    data:config

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check-rollout-status.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./check-rollout-status.sh

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat check_rollout_status.json
    ...    env=${env}

    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for rollout status task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END

    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=Deployment `${DEPLOYMENT_NAME}` rollout should complete with updated, available, and ready replicas aligned
            ...    actual=${issue['title']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END

    RW.Core.Add Pre To Report    Rollout Status Analysis:
    RW.Core.Add Pre To Report    ${result.stdout}

Compare Deployment ReplicaSets During Rollout for `${DEPLOYMENT_NAME}` in Namespace `${NAMESPACE}`
    [Documentation]    Compares the latest ReplicaSet against older ReplicaSets and flags conflicting active ReplicaSets or outdated pods blocking rollout completion.
    [Tags]    Kubernetes    Deployment    ReplicaSet    Rollout    access:read-only    data:config

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=compare-replicasets-during-rollout.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./compare-replicasets-during-rollout.sh

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat compare_replicasets_during_rollout.json
    ...    env=${env}

    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for ReplicaSet comparison task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END

    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=Only the latest ReplicaSet should serve traffic after rollout completes
            ...    actual=${issue['title']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END

    RW.Core.Add Pre To Report    ReplicaSet Comparison Analysis:
    RW.Core.Add Pre To Report    ${result.stdout}

Inspect New ReplicaSet Pod Failures for `${DEPLOYMENT_NAME}` in Namespace `${NAMESPACE}`
    [Documentation]    Focuses on pods owned by the latest ReplicaSet that block rollout completion due to scheduling, image pull, crash, or readiness failures.
    [Tags]    Kubernetes    Deployment    Pods    Failures    access:read-only    data:logs-config

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=inspect-new-replicaset-pod-failures.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./inspect-new-replicaset-pod-failures.sh

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat inspect_new_replicaset_pod_failures.json
    ...    env=${env}

    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for new ReplicaSet pod failures task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END

    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=New ReplicaSet pods should start and become Ready
            ...    actual=${issue['title']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END

    RW.Core.Add Pre To Report    New ReplicaSet Pod Failure Analysis:
    RW.Core.Add Pre To Report    ${result.stdout}

Check Rollout Strategy Configuration for `${DEPLOYMENT_NAME}` in Namespace `${NAMESPACE}`
    [Documentation]    Reviews deployment update strategy, maxUnavailable, maxSurge, progressDeadlineSeconds, revisionHistoryLimit, and paused state for rollout-stalling configurations.
    [Tags]    Kubernetes    Deployment    Strategy    Configuration    access:read-only    data:config

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check-rollout-strategy-config.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./check-rollout-strategy-config.sh

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat check_rollout_strategy_config.json
    ...    env=${env}

    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for rollout strategy config task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END

    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=Rollout strategy should allow safe, timely pod replacement
            ...    actual=${issue['title']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END

    RW.Core.Add Pre To Report    Rollout Strategy Configuration Analysis:
    RW.Core.Add Pre To Report    ${result.stdout}

Check PodDisruptionBudget Impact on Rollout for `${DEPLOYMENT_NAME}` in Namespace `${NAMESPACE}`
    [Documentation]    Finds PDBs whose selectors match the deployment and evaluates whether minAvailable or maxUnavailable constraints block rollout eviction or scheduling.
    [Tags]    Kubernetes    Deployment    PDB    Rollout    access:read-only    data:config

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check-pdb-rollout-impact.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./check-pdb-rollout-impact.sh

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat check_pdb_rollout_impact.json
    ...    env=${env}

    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for PDB rollout impact task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END

    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=PDB constraints should not prevent necessary pod disruption during rollout
            ...    actual=${issue['title']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END

    RW.Core.Add Pre To Report    PDB Rollout Impact Analysis:
    RW.Core.Add Pre To Report    ${result.stdout}

Detect Rollout Blocking Events for `${DEPLOYMENT_NAME}` in Namespace `${NAMESPACE}`
    [Documentation]    Surfaces recent Warning and Error events on the deployment, its ReplicaSets, and rollout pods within the configured time window.
    [Tags]    Kubernetes    Deployment    Events    Rollout    access:read-only    data:logs-config

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=detect-rollout-blocking-events.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./detect-rollout-blocking-events.sh

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat detect_rollout_blocking_events.json
    ...    env=${env}

    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for rollout blocking events task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END

    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=No blocking Warning or Error events during rollout
            ...    actual=${issue['title']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END

    RW.Core.Add Pre To Report    Rollout Blocking Events Analysis:
    RW.Core.Add Pre To Report    ${result.stdout}

Check Stuck Terminating Pods Blocking Rollout for `${DEPLOYMENT_NAME}` in Namespace `${NAMESPACE}`
    [Documentation]    Identifies deployment pods stuck in Terminating state that prevent old ReplicaSet scale-down and block rollout completion.
    [Tags]    Kubernetes    Deployment    Pods    Terminating    access:read-only    data:config

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check-stuck-terminating-pods.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./check-stuck-terminating-pods.sh

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat check_stuck_terminating_pods.json
    ...    env=${env}

    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for stuck terminating pods task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END

    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=Old ReplicaSet pods should terminate promptly during rollout
            ...    actual=${issue['title']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END

    RW.Core.Add Pre To Report    Stuck Terminating Pods Analysis:
    RW.Core.Add Pre To Report    ${result.stdout}

Fetch Rollout History for `${DEPLOYMENT_NAME}` in Namespace `${NAMESPACE}`
    [Documentation]    Retrieves rollout revision history and summarizes recent template changes to correlate failed rollouts with specific revisions.
    [Tags]    Kubernetes    Deployment    History    Revision    access:read-only    data:config

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=fetch-rollout-history.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./fetch-rollout-history.sh

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat fetch_rollout_history.json
    ...    env=${env}

    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for rollout history task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END

    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=Recent revisions should not introduce breaking template changes during rollout
            ...    actual=${issue['title']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END

    RW.Core.Add Pre To Report    Rollout History Analysis:
    RW.Core.Add Pre To Report    ${result.stdout}


*** Keywords ***
Suite Initialization
    ${kubeconfig}=    RW.Core.Import Secret    kubeconfig
    ...    type=string
    ...    description=The kubernetes kubeconfig yaml containing connection configuration used to connect to cluster(s).
    ...    pattern=\w*
    ${CONTEXT}=    RW.Core.Import User Variable    CONTEXT
    ...    type=string
    ...    description=Kubernetes context to operate within.
    ...    pattern=\w*
    ${NAMESPACE}=    RW.Core.Import User Variable    NAMESPACE
    ...    type=string
    ...    description=Namespace containing the deployment.
    ...    pattern=\w*
    ${DEPLOYMENT_NAME}=    RW.Core.Import User Variable    DEPLOYMENT_NAME
    ...    type=string
    ...    description=Name of the deployment to troubleshoot.
    ...    pattern=\w*
    ${KUBERNETES_DISTRIBUTION_BINARY}=    RW.Core.Import User Variable    KUBERNETES_DISTRIBUTION_BINARY
    ...    type=string
    ...    description=Kubernetes CLI binary (kubectl or oc).
    ...    enum=[kubectl,oc]
    ...    default=kubectl
    ${EVENT_AGE}=    RW.Core.Import User Variable    EVENT_AGE
    ...    type=string
    ...    description=Lookback window for rollout-related events (e.g. 30m, 1h).
    ...    pattern=\w*
    ...    default=30m
    ${ROLLOUT_STATUS_TIMEOUT}=    RW.Core.Import User Variable    ROLLOUT_STATUS_TIMEOUT
    ...    type=string
    ...    description=Seconds to wait when sampling rollout status (non-blocking sample).
    ...    pattern=^\d+$
    ...    default=30
    ${STUCK_TERMINATING_THRESHOLD}=    RW.Core.Import User Variable    STUCK_TERMINATING_THRESHOLD
    ...    type=string
    ...    description=Minutes a pod may remain Terminating before raising an issue.
    ...    pattern=^\d+$
    ...    default=5

    Set Suite Variable    ${kubeconfig}    ${kubeconfig}
    Set Suite Variable    ${CONTEXT}    ${CONTEXT}
    Set Suite Variable    ${NAMESPACE}    ${NAMESPACE}
    Set Suite Variable    ${DEPLOYMENT_NAME}    ${DEPLOYMENT_NAME}
    Set Suite Variable    ${KUBERNETES_DISTRIBUTION_BINARY}    ${KUBERNETES_DISTRIBUTION_BINARY}
    Set Suite Variable    ${EVENT_AGE}    ${EVENT_AGE}
    Set Suite Variable    ${ROLLOUT_STATUS_TIMEOUT}    ${ROLLOUT_STATUS_TIMEOUT}
    Set Suite Variable    ${STUCK_TERMINATING_THRESHOLD}    ${STUCK_TERMINATING_THRESHOLD}

    ${env_dict}=    Create Dictionary
    ...    CONTEXT=${CONTEXT}
    ...    NAMESPACE=${NAMESPACE}
    ...    DEPLOYMENT_NAME=${DEPLOYMENT_NAME}
    ...    KUBERNETES_DISTRIBUTION_BINARY=${KUBERNETES_DISTRIBUTION_BINARY}
    ...    EVENT_AGE=${EVENT_AGE}
    ...    ROLLOUT_STATUS_TIMEOUT=${ROLLOUT_STATUS_TIMEOUT}
    ...    STUCK_TERMINATING_THRESHOLD=${STUCK_TERMINATING_THRESHOLD}
    Set Suite Variable    ${env}    ${env_dict}
