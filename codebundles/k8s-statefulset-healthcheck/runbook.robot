*** Settings ***
Documentation       Triages issues related to a StatefulSet and its pods.
Metadata            Author    stewartshea
Metadata            Display Name    Kubernetes StatefulSet Triage
Metadata            Supports    Kubernetes,AKS,EKS,GKE,OpenShift

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             RW.NextSteps
Library             RW.K8sHelper
Library             RW.K8sLog
Library             OperatingSystem
Library             String

Suite Setup         Suite Initialization


*** Tasks ***
Analyze Application Log Patterns for StatefulSet `${STATEFULSET_NAME}` in Namespace `${NAMESPACE}`
    [Documentation]    Fetches and analyzes logs from the StatefulSet pods for errors, stack traces, connection issues, and other patterns that indicate application health problems.
    [Tags]
    ...    logs
    ...    application
    ...    errors
    ...    patterns
    ...    health
    ...    statefulset
    ...    ${STATEFULSET_NAME}
    ...    access:read-only
    ${log_dir}=    RW.K8sLog.Fetch Workload Logs
    ...    statefulset
    ...    ${STATEFULSET_NAME}
    ...    ${NAMESPACE}
    ...    ${CONTEXT}
    ...    ${kubeconfig.content}
    ...    ${LOG_AGE}
    
    ${scan_results}=    RW.K8sLog.Scan Logs For Issues
    ...    ${log_dir}
    ...    statefulset
    ...    ${STATEFULSET_NAME}
    ...    ${NAMESPACE}
    ...    @{LOG_PATTERN_CATEGORIES}
    
    ${log_health_score}=    RW.K8sLog.Calculate Log Health Score    ${scan_results}
    
    # Process each issue found in the logs
    ${issues}=    Evaluate    $scan_results.get('issues', [])
    IF    len($issues) > 0
        FOR    ${issue}    IN    @{issues}
            ${summarized_details}=    RW.K8sLog.Summarize Log Issues    ${issue["details"]}
            ${next_steps_text}=    Catenate    SEPARATOR=\n    @{issue["next_steps"]}
            
            RW.Core.Add Issue
            ...    severity=${issue["severity"]}
            ...    expected=No application errors should be present in StatefulSet `${STATEFULSET_NAME}` logs in namespace `${NAMESPACE}`
            ...    actual=Application errors detected in StatefulSet `${STATEFULSET_NAME}` logs in namespace `${NAMESPACE}`
            ...    title=${issue["title"]}
            ...    reproduce_hint=Use RW.K8sLog.Fetch Workload Logs and RW.K8sLog.Scan Logs For Issues keywords to reproduce this analysis
            ...    details=${summarized_details}
            ...    next_steps=${next_steps_text}
        END
    END
    
    # Add summary to report
    ${summary_text}=    Catenate    SEPARATOR=\n    @{scan_results["summary"]}
    RW.Core.Add Pre To Report    Application Log Analysis Summary for StatefulSet ${STATEFULSET_NAME}:\n${summary_text}
    RW.Core.Add Pre To Report    Log Health Score: ${log_health_score} (1.0 = healthy, 0.0 = unhealthy)
    
    RW.K8sLog.Cleanup Temp Files

Detect Log Anomalies for StatefulSet `${STATEFULSET_NAME}` in Namespace `${NAMESPACE}`
    [Documentation]    Analyzes logs for repeating patterns, anomalous behavior, and unusual log volume that may indicate underlying issues.
    [Tags]
    ...    logs
    ...    anomalies
    ...    patterns
    ...    volume
    ...    statefulset
    ...    ${STATEFULSET_NAME}
    ...    access:read-only
    ${log_dir}=    RW.K8sLog.Fetch Workload Logs
    ...    statefulset
    ...    ${STATEFULSET_NAME}
    ...    ${NAMESPACE}
    ...    ${CONTEXT}
    ...    ${kubeconfig.content}
    ...    ${LOG_AGE}
    
    ${anomaly_results}=    RW.K8sLog.Analyze Log Anomalies
    ...    ${log_dir}
    ...    statefulset
    ...    ${STATEFULSET_NAME}
    ...    ${NAMESPACE}
    
    # Process anomaly issues
    ${anomaly_issues}=    Evaluate    $anomaly_results.get('issues', [])
    IF    len($anomaly_issues) > 0
        FOR    ${issue}    IN    @{anomaly_issues}
            ${summarized_details}=    RW.K8sLog.Summarize Log Issues    ${issue["details"]}
            ${next_steps_text}=    Catenate    SEPARATOR=\n    @{issue["next_steps"]}
            
            RW.Core.Add Issue
            ...    severity=${issue["severity"]}
            ...    expected=No log anomalies should be present in StatefulSet `${STATEFULSET_NAME}` in namespace `${NAMESPACE}`
            ...    actual=Log anomalies detected in StatefulSet `${STATEFULSET_NAME}` in namespace `${NAMESPACE}`
            ...    title=${issue["title"]}
            ...    reproduce_hint=Use RW.K8sLog.Analyze Log Anomalies keyword to reproduce this analysis
            ...    details=${summarized_details}
            ...    next_steps=${next_steps_text}
        END
    END
    
    # Add summary to report
    ${anomaly_summary}=    Catenate    SEPARATOR=\n    @{anomaly_results["summary"]}
    RW.Core.Add Pre To Report    Log Anomaly Analysis for StatefulSet ${STATEFULSET_NAME}:\n${anomaly_summary}
    
    RW.K8sLog.Cleanup Temp Files

Check StatefulSet Status for `${STATEFULSET_NAME}` in Namespace `${NAMESPACE}`
    [Documentation]    Checks the status of the StatefulSet and identifies any issues with pod readiness or availability.
    [Tags]
    ...    statefulset
    ...    status
    ...    availability
    ...    replicas
    ...    ${STATEFULSET_NAME}
    ...    access:read-only
    ${ss_status}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get statefulset ${STATEFULSET_NAME} -n ${NAMESPACE} --context ${CONTEXT} -o json
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    show_in_rwl_cheatsheet=true
    
    ${status_data}=    Evaluate    json.loads(r'''${ss_status.stdout}''')    json
    ${desired_replicas}=    Set Variable    ${status_data["spec"]["replicas"]}
    ${ready_replicas}=    Set Variable    ${status_data["status"].get("readyReplicas", 0)}
    ${current_replicas}=    Set Variable    ${status_data["status"].get("currentReplicas", 0)}
    
    IF    ${ready_replicas} < ${desired_replicas}
        RW.Core.Add Issue
        ...    severity=2
        ...    expected=StatefulSet `${STATEFULSET_NAME}` should have ${desired_replicas} ready replicas in namespace `${NAMESPACE}`
        ...    actual=StatefulSet `${STATEFULSET_NAME}` has ${ready_replicas} ready replicas in namespace `${NAMESPACE}`
        ...    title=StatefulSet `${STATEFULSET_NAME}` in Namespace `${NAMESPACE}` has unhealthy replicas
        ...    reproduce_hint=${ss_status.cmd}
        ...    details=StatefulSet ${STATEFULSET_NAME} has ${ready_replicas}/${desired_replicas} ready replicas
        ...    next_steps=Check pod status and events for StatefulSet pods\nInvestigate container restarts\nCheck persistent volume claims if applicable
    END
    
    RW.Core.Add Pre To Report    StatefulSet Status:\n${ss_status.stdout}
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Commands Used: ${history}


*** Keywords ***
Suite Initialization
    ${kubeconfig}=    RW.Core.Import Secret
    ...    kubeconfig
    ...    type=string
    ...    description=The kubernetes kubeconfig yaml containing connection configuration used to connect to cluster(s).
    ...    pattern=\w*
    ...    example=For examples, start here https://kubernetes.io/docs/concepts/configuration/organize-cluster-access-kubeconfig/
    ${STATEFULSET_NAME}=    RW.Core.Import User Variable    STATEFULSET_NAME
    ...    type=string
    ...    description=Used to target the StatefulSet resource for queries and filtering events.
    ...    pattern=\w*
    ...    example=mysql-primary
    ${NAMESPACE}=    RW.Core.Import User Variable    NAMESPACE
    ...    type=string
    ...    description=The name of the Kubernetes namespace to scope actions and searching to.
    ...    pattern=\w*
    ...    example=my-namespace
    ${CONTEXT}=    RW.Core.Import User Variable    CONTEXT
    ...    type=string
    ...    description=Which Kubernetes context to operate within.
    ...    pattern=\w*
    ...    example=my-main-cluster
    ${KUBERNETES_DISTRIBUTION_BINARY}=    RW.Core.Import User Variable    KUBERNETES_DISTRIBUTION_BINARY
    ...    type=string
    ...    description=Which binary to use for Kubernetes CLI commands.
    ...    enum=[kubectl,oc]
    ...    example=kubectl
    ...    default=kubectl
    ${LOG_AGE}=    RW.Core.Import User Variable    LOG_AGE
    ...    type=string
    ...    description=How far back to analyze logs (e.g., 10m, 1h, 2h)
    ...    pattern=\w*
    ...    example=30m
    ...    default=10m
    ${LOG_PATTERN_CATEGORIES}=    RW.Core.Import User Variable    LOG_PATTERN_CATEGORIES
    ...    type=string
    ...    description=Comma-separated list of log pattern categories to analyze
    ...    pattern=\w*
    ...    example=GenericError,StackTrace,Connection,Timeout
    ...    default=GenericError,AppFailure,StackTrace,Connection,Timeout,Auth,Exceptions,Resource
    # Convert comma-separated string to list
    @{category_list}=    Split String    ${LOG_PATTERN_CATEGORIES}    ,
    @{category_list}=    Evaluate    [cat.strip() for cat in $category_list]
    Set Suite Variable    ${LOG_AGE}    ${LOG_AGE}
    Set Suite Variable    @{LOG_PATTERN_CATEGORIES}    @{category_list}
    Set Suite Variable    ${kubeconfig}    ${kubeconfig}
    Set Suite Variable    ${KUBERNETES_DISTRIBUTION_BINARY}    ${KUBERNETES_DISTRIBUTION_BINARY}
    Set Suite Variable    ${CONTEXT}    ${CONTEXT}
    Set Suite Variable    ${NAMESPACE}    ${NAMESPACE}
    Set Suite Variable    ${STATEFULSET_NAME}    ${STATEFULSET_NAME}
    Set Suite Variable
    ...    ${env}
    ...    {"KUBECONFIG":"./${kubeconfig.key}", "KUBERNETES_DISTRIBUTION_BINARY":"${KUBERNETES_DISTRIBUTION_BINARY}", "CONTEXT":"${CONTEXT}", "NAMESPACE":"${NAMESPACE}", "STATEFULSET_NAME": "${STATEFULSET_NAME}"}
