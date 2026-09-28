*** Settings ***
Documentation       Collects Kubernetes health signals for Apache Airflow workloads: controllers, pods, events, PVCs, scheduler logs, and executor pods to diagnose misconfiguration and executor failures without mutating the cluster.
Metadata            Author    rw-codebundle-agent
Metadata            Display Name    Kubernetes Airflow Workload Diagnostics
Metadata            Supports    Kubernetes Airflow Workload Diagnostics

Library             String
Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.K8sHelper
Library             RW.platform

Force Tags          Kubernetes    Airflow    Workload    Diagnostics

Suite Setup         Suite Initialization


*** Tasks ***
List Airflow Workloads in Namespace `${NAMESPACE}`
    [Documentation]    Discovers Deployments, StatefulSets, and DaemonSets associated with Airflow via label selectors and name prefix; compares desired versus ready replicas.
    [Tags]    Kubernetes    Airflow    access:read-only    data:logs-config

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=list-airflow-workloads.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./list-airflow-workloads.sh

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat list_airflow_workloads_issues.json
    ...    env=${env}
    ...    include_in_history=false

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
            ...    expected=Airflow-related workloads should have ready replicas matching desired counts in namespace `${NAMESPACE}`
            ...    actual=Replica mismatch or API error reported for workloads in namespace `${NAMESPACE}`
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END

    RW.Core.Add Pre To Report    Airflow workload listing:
    RW.Core.Add Pre To Report    ${result.stdout}

Check Airflow Pod Health and Restarts in Namespace `${NAMESPACE}`
    [Documentation]    Evaluates Airflow-labeled pods for phase, Ready condition, restart counts, and recent termination reasons such as OOMKilled or Error.
    [Tags]    Kubernetes    Airflow    access:read-only    data:metrics

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check-airflow-pod-health.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./check-airflow-pod-health.sh

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat check_airflow_pod_health_issues.json
    ...    env=${env}
    ...    include_in_history=false

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
            ...    expected=Airflow pods should be Running and Ready with stable containers in namespace `${NAMESPACE}`
            ...    actual=Pod health issue detected among Airflow-labeled pods in namespace `${NAMESPACE}`
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END

    RW.Core.Add Pre To Report    Airflow pod health check:
    RW.Core.Add Pre To Report    ${result.stdout}

Fetch Recent Events for Airflow Resources in Namespace `${NAMESPACE}`
    [Documentation]    Pulls Warning events in the lookback window for objects tied to Airflow pods or workload names to catch scheduling, volume, and probe failures.
    [Tags]    Kubernetes    Airflow    access:read-only    data:logs-config

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=fetch-airflow-events.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./fetch-airflow-events.sh

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat fetch_airflow_events_issues.json
    ...    env=${env}
    ...    include_in_history=false

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
            ...    expected=No unexpected Warning events for Airflow-related objects in namespace `${NAMESPACE}` during the lookback window
            ...    actual=Warning events matched Airflow-related resources in namespace `${NAMESPACE}`
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END

    RW.Core.Add Pre To Report    Airflow-related Warning events:
    RW.Core.Add Pre To Report    ${result.stdout}

Summarize PVC Status for Airflow Data Volumes in Namespace `${NAMESPACE}`
    [Documentation]    Lists PVCs tied to Airflow pods or common volume name patterns and flags phases such as Pending that indicate storage provisioning problems.
    [Tags]    Kubernetes    Airflow    access:read-only    data:logs-config

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=summarize-airflow-pvcs.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./summarize-airflow-pvcs.sh

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat summarize_airflow_pvcs_issues.json
    ...    env=${env}
    ...    include_in_history=false

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
            ...    expected=Airflow-related PVCs should be Bound and provisioned in namespace `${NAMESPACE}`
            ...    actual=PVC phase or provisioning issue detected in namespace `${NAMESPACE}`
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END

    RW.Core.Add Pre To Report    Airflow PVC summary:
    RW.Core.Add Pre To Report    ${result.stdout}

Sample Scheduler Logs for DAG Import Errors in Namespace `${NAMESPACE}`
    [Documentation]    Reads recent scheduler pod logs within the lookback window and flags common DAG import, traceback, or database connectivity patterns without executing DAGs.
    [Tags]    Kubernetes    Airflow    access:read-only    data:logs

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=sample-airflow-scheduler-logs.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./sample-airflow-scheduler-logs.sh

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat sample_airflow_scheduler_logs_issues.json
    ...    env=${env}
    ...    include_in_history=false

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
            ...    expected=Scheduler logs should be free of DAG import failures and critical connectivity errors in namespace `${NAMESPACE}`
            ...    actual=Log patterns indicated potential DAG or database issues in namespace `${NAMESPACE}`
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END

    RW.Core.Add Pre To Report    Scheduler log sampling:
    RW.Core.Add Pre To Report    ${result.stdout}

Check Worker or KubernetesExecutor Pod Saturation in Namespace `${NAMESPACE}`
    [Documentation]    When Celery or executor-style pods are present, surfaces Pending scheduling problems and OOM terminations using pod status (best-effort, read-only).
    [Tags]    Kubernetes    Airflow    access:read-only    data:metrics

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check-airflow-executor-pods.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./check-airflow-executor-pods.sh

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat check_airflow_executor_pods_issues.json
    ...    env=${env}
    ...    include_in_history=false

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
            ...    expected=Executor and worker pods should schedule cleanly without OOM terminations in namespace `${NAMESPACE}`
            ...    actual=Executor-related pod issue detected in namespace `${NAMESPACE}`
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END

    RW.Core.Add Pre To Report    Executor pod check:
    RW.Core.Add Pre To Report    ${result.stdout}


*** Keywords ***
Suite Initialization
    ${kubeconfig}=    RW.Core.Import Secret
    ...    kubeconfig
    ...    type=string
    ...    description=Kubernetes kubeconfig with read-only list/get/describe/logs on workloads.
    ...    pattern=\w*
    ${KUBERNETES_DISTRIBUTION_BINARY}=    RW.Core.Import User Variable    KUBERNETES_DISTRIBUTION_BINARY
    ...    type=string
    ...    description=Kubernetes CLI binary to use.
    ...    enum=[kubectl,oc]
    ...    default=kubectl
    ...    pattern=\w*
    ${CONTEXT}=    RW.Core.Import User Variable    CONTEXT
    ...    type=string
    ...    description=Kubernetes context name.
    ...    pattern=[^\\s]+
    ${NAMESPACE}=    RW.Core.Import User Variable    NAMESPACE
    ...    type=string
    ...    description=Namespace that contains the Airflow release.
    ...    pattern=[^\\s]+
    ${AIRFLOW_LABEL_SELECTOR}=    RW.Core.Import User Variable    AIRFLOW_LABEL_SELECTOR
    ...    type=string
    ...    description=Label selector for Airflow workloads (pods, controllers).
    ...    default=app.kubernetes.io/name=airflow
    ...    pattern=.*
    ${AIRFLOW_DEPLOYMENT_NAME_PREFIX}=    RW.Core.Import User Variable    AIRFLOW_DEPLOYMENT_NAME_PREFIX
    ...    type=string
    ...    description=Name prefix to match controllers when labels are inconsistent.
    ...    default=airflow
    ...    pattern=.*
    ${RW_LOOKBACK_WINDOW}=    RW.Core.Import User Variable    RW_LOOKBACK_WINDOW
    ...    type=string
    ...    description=Lookback window for events and log sampling (for example 30m, 1h).
    ...    default=1h
    ...    pattern=.*

    Set Suite Variable    ${kubeconfig}    ${kubeconfig}
    Set Suite Variable    ${KUBERNETES_DISTRIBUTION_BINARY}    ${KUBERNETES_DISTRIBUTION_BINARY}
    Set Suite Variable    ${CONTEXT}    ${CONTEXT}
    Set Suite Variable    ${NAMESPACE}    ${NAMESPACE}
    Set Suite Variable    ${AIRFLOW_LABEL_SELECTOR}    ${AIRFLOW_LABEL_SELECTOR}
    Set Suite Variable    ${AIRFLOW_DEPLOYMENT_NAME_PREFIX}    ${AIRFLOW_DEPLOYMENT_NAME_PREFIX}
    Set Suite Variable    ${RW_LOOKBACK_WINDOW}    ${RW_LOOKBACK_WINDOW}

    ${env}=    Create Dictionary
    ...    KUBECONFIG=./${kubeconfig.key}
    ...    CONTEXT=${CONTEXT}
    ...    NAMESPACE=${NAMESPACE}
    ...    KUBERNETES_DISTRIBUTION_BINARY=${KUBERNETES_DISTRIBUTION_BINARY}
    ...    AIRFLOW_LABEL_SELECTOR=${AIRFLOW_LABEL_SELECTOR}
    ...    AIRFLOW_DEPLOYMENT_NAME_PREFIX=${AIRFLOW_DEPLOYMENT_NAME_PREFIX}
    ...    RW_LOOKBACK_WINDOW=${RW_LOOKBACK_WINDOW}
    Set Suite Variable    ${env}    ${env}

    RW.K8sHelper.Verify Cluster Connectivity
    ...    binary=${KUBERNETES_DISTRIBUTION_BINARY}
    ...    context=${CONTEXT}
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
