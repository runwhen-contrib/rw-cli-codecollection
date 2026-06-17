*** Settings ***
Documentation       Measures Airflow namespace workload health using workload readiness, pod readiness, and Warning event volume. Produces a value between 0 (failing) and 1 (healthy).
Metadata            Author    rw-codebundle-agent
Metadata            Display Name    Kubernetes Airflow Workload Diagnostics
Metadata            Supports    Kubernetes Airflow Workload Diagnostics

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             OperatingSystem
Library             Collections

Suite Setup         Suite Initialization


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
    ...    description=Label selector for Airflow workloads.
    ...    default=app.kubernetes.io/name=airflow
    ...    pattern=.*
    ${AIRFLOW_DEPLOYMENT_NAME_PREFIX}=    RW.Core.Import User Variable    AIRFLOW_DEPLOYMENT_NAME_PREFIX
    ...    type=string
    ...    description=Name prefix to match controllers when labels are inconsistent.
    ...    default=airflow
    ...    pattern=.*
    ${RW_LOOKBACK_WINDOW}=    RW.Core.Import User Variable    RW_LOOKBACK_WINDOW
    ...    type=string
    ...    description=Lookback window for event counting (for example 30m, 1h).
    ...    default=1h
    ...    pattern=.*
    ${AIRFLOW_SLI_EVENT_THRESHOLD}=    RW.Core.Import User Variable    AIRFLOW_SLI_EVENT_THRESHOLD
    ...    type=string
    ...    description=Maximum Warning events in the lookback window before the events sub-score fails.
    ...    default=8
    ...    pattern=^\\d+$

    Set Suite Variable    ${kubeconfig}    ${kubeconfig}
    Set Suite Variable    ${KUBERNETES_DISTRIBUTION_BINARY}    ${KUBERNETES_DISTRIBUTION_BINARY}
    Set Suite Variable    ${CONTEXT}    ${CONTEXT}
    Set Suite Variable    ${NAMESPACE}    ${NAMESPACE}
    Set Suite Variable    ${AIRFLOW_LABEL_SELECTOR}    ${AIRFLOW_LABEL_SELECTOR}
    Set Suite Variable    ${AIRFLOW_DEPLOYMENT_NAME_PREFIX}    ${AIRFLOW_DEPLOYMENT_NAME_PREFIX}
    Set Suite Variable    ${RW_LOOKBACK_WINDOW}    ${RW_LOOKBACK_WINDOW}
    Set Suite Variable    ${AIRFLOW_SLI_EVENT_THRESHOLD}    ${AIRFLOW_SLI_EVENT_THRESHOLD}

    ${env}=    Create Dictionary
    ...    KUBECONFIG=./${kubeconfig.key}
    ...    CONTEXT=${CONTEXT}
    ...    NAMESPACE=${NAMESPACE}
    ...    KUBERNETES_DISTRIBUTION_BINARY=${KUBERNETES_DISTRIBUTION_BINARY}
    ...    AIRFLOW_LABEL_SELECTOR=${AIRFLOW_LABEL_SELECTOR}
    ...    AIRFLOW_DEPLOYMENT_NAME_PREFIX=${AIRFLOW_DEPLOYMENT_NAME_PREFIX}
    ...    RW_LOOKBACK_WINDOW=${RW_LOOKBACK_WINDOW}
    ...    AIRFLOW_SLI_EVENT_THRESHOLD=${AIRFLOW_SLI_EVENT_THRESHOLD}
    Set Suite Variable    ${env}    ${env}


*** Tasks ***
Generate Airflow Workload Health Score for Namespace `${NAMESPACE}`
    [Documentation]    Runs a lightweight kubectl summary, pushes binary sub-scores for workload readiness, pod readiness, and Warning event volume, then averages them into a 0-1 health metric.
    [Tags]    access:read-only    data:metrics

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=sli-airflow-health.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    timeout_seconds=120
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./sli-airflow-health.sh

    TRY
        ${m}=    Evaluate    json.loads(r'''${result.stdout}''')    json
        ${ws}=    Convert To Number    ${m['workload']}
        ${ps}=    Convert To Number    ${m['pods']}
        ${es}=    Convert To Number    ${m['events']}
    EXCEPT
        Log    SLI JSON parse failed; scoring zero.    WARN
        ${ws}=    Set Variable    ${0}
        ${ps}=    Set Variable    ${0}
        ${es}=    Set Variable    ${0}
    END

    RW.Core.Push Metric    ${ws}    sub_name=workload_readiness
    RW.Core.Push Metric    ${ps}    sub_name=pod_readiness
    RW.Core.Push Metric    ${es}    sub_name=warning_events

    ${health_score}=    Evaluate    (${ws} + ${ps} + ${es}) / 3
    ${health_score}=    Convert to Number    ${health_score}    2
    RW.Core.Add to Report    Airflow workload health score: ${health_score} (workload=${ws}, pods=${ps}, events=${es})
    RW.Core.Push Metric    ${health_score}
