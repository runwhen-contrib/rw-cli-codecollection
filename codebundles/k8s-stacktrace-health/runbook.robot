*** Settings ***
Documentation       Detects and analyzes stacktraces/tracebacks in Kubernetes workload logs for troubleshooting application issues.
Metadata            Author    akshayrw25
Metadata            Display Name    Kubernetes Workload Stacktrace Analysis
Metadata            Supports    Kubernetes,AKS,EKS,GKE,OpenShift

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             RW.NextSteps
Library             RW.K8sHelper
Library             RW.K8sLog
Library             RW.LogAnalysis.ExtractTraceback
Library             OperatingSystem
Library             String
Library             Collections

Suite Setup         Suite Initialization


*** Keywords ***
Suite Initialization
    ${kubeconfig}=    RW.Core.Import Secret
    ...    kubeconfig
    ...    type=string
    ...    description=The kubernetes kubeconfig yaml containing connection configuration used to connect to cluster(s).
    ...    pattern=\w*
    ...    example=For examples, start here https://kubernetes.io/docs/concepts/configuration/organize-cluster-access-kubeconfig/
    ${KUBERNETES_DISTRIBUTION_BINARY}=    RW.Core.Import User Variable    KUBERNETES_DISTRIBUTION_BINARY
    ...    type=string
    ...    description=Which binary to use for Kubernetes CLI commands.
    ...    pattern=\w*
    ...    enum=[kubectl,oc]
    ...    example=kubectl
    ...    default=kubectl
    ${CONTEXT}=    RW.Core.Import User Variable    CONTEXT
    ...    type=string
    ...    description=Which Kubernetes context to operate within.
    ...    pattern=\w*
    ...    example=my-main-cluster
    ${NAMESPACE}=    RW.Core.Import User Variable    NAMESPACE
    ...    type=string
    ...    description=The name of the Kubernetes namespace to scope actions and searching to.
    ...    pattern=\w*
    ...    example=otel-demo
    ${WORKLOAD_NAME}=    RW.Core.Import User Variable    WORKLOAD_NAME
    ...    type=string
    ...    description=The name of the workload (deployment, statefulset, or daemonset) to analyze for stacktraces.
    ...    pattern=\w*
    ...    example=otel-demo-frontend
    ${WORKLOAD_TYPE}=    RW.Core.Import User Variable    WORKLOAD_TYPE
    ...    type=string
    ...    description=The type of Kubernetes workload to analyze.
    ...    pattern=\w*
    ...    enum=[deployment,statefulset,daemonset]
    ...    example=deployment
    ...    default=deployment
    ${LOG_LINES}=    RW.Core.Import User Variable    LOG_LINES
    ...    type=string
    ...    description=The number of log lines to fetch from the pods when inspecting logs.
    ...    pattern=\d+
    ...    example=100
    ...    default=2000
    ${LOG_AGE}=    RW.Core.Import User Variable    LOG_AGE
    ...    type=string
    ...    description=The age of logs to fetch from pods, used for log analysis tasks.
    ...    pattern=\w*
    ...    example=1h
    ...    default=15m
    ${LOG_SIZE}=    RW.Core.Import User Variable    LOG_SIZE
    ...    type=string
    ...    description=The maximum size of logs in bytes to fetch from pods, used for log analysis tasks. Defaults to 2MB.
    ...    pattern=\d*
    ...    example=1024
    ...    default=2097152
    ${EXCLUDED_CONTAINER_NAMES}=    RW.Core.Import User Variable    EXCLUDED_CONTAINER_NAMES
    ...    type=string
    ...    description=comma-separated string of keywords used to identify and skip container names containing any of these substrings."
    ...    pattern=\w*
    ...    example=linkerd-proxy,istio-proxy,vault-agent
    ...    default=linkerd-proxy,istio-proxy,vault-agent
    
    Set Suite Variable    ${kubeconfig}    ${kubeconfig}
    Set Suite Variable    ${KUBERNETES_DISTRIBUTION_BINARY}
    Set Suite Variable    ${CONTEXT}
    Set Suite Variable    ${NAMESPACE}
    Set Suite Variable    ${WORKLOAD_NAME}
    Set Suite Variable    ${WORKLOAD_TYPE}
    Set Suite Variable    ${LOG_LINES}
    Set Suite Variable    ${LOG_AGE}
    Set Suite Variable    ${LOG_SIZE}
    Set Suite Variable    ${EXCLUDED_CONTAINER_NAMES}
    
    # Construct environment dictionary safely to handle special characters in regex patterns
    &{env_dict}=    Create Dictionary    
    ...    KUBECONFIG=${kubeconfig.key}
    ...    KUBERNETES_DISTRIBUTION_BINARY=${KUBERNETES_DISTRIBUTION_BINARY}
    ...    CONTEXT=${CONTEXT}
    ...    NAMESPACE=${NAMESPACE}
    ...    WORKLOAD_NAME=${WORKLOAD_NAME}
    ...    WORKLOAD_TYPE=${WORKLOAD_TYPE}
    Set Suite Variable    ${env}    ${env_dict}

    # Verify cluster connectivity
    ${connectivity}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} cluster-info --context ${CONTEXT}
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    timeout_seconds=30
    IF    ${connectivity.returncode} != 0
        RW.Core.Add Issue
        ...    severity=3
        ...    expected=Kubernetes cluster should be reachable via configured kubeconfig and context `${CONTEXT}`
        ...    actual=Unable to connect to Kubernetes cluster with context `${CONTEXT}`
        ...    title=Kubernetes Cluster Connectivity Check Failed for Context `${CONTEXT}`
        ...    reproduce_hint=${KUBERNETES_DISTRIBUTION_BINARY} cluster-info --context ${CONTEXT}
        ...    details=Failed to connect to the Kubernetes cluster. This may indicate an expired kubeconfig, network connectivity issues, or the cluster being unreachable.\n\nSTDOUT:\n${connectivity.stdout}\n\nSTDERR:\n${connectivity.stderr}
        ...    next_steps=Verify kubeconfig is valid and not expired\nCheck network connectivity to the cluster API server\nVerify the context '${CONTEXT}' is correctly configured\nCheck if the cluster is running and accessible
        BuiltIn.Fatal Error    Kubernetes cluster connectivity check failed for context '${CONTEXT}'. Aborting suite.
    END
    
    # Check if deployment is scaled to 0 and handle appropriately
    ${scale_check}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get ${WORKLOAD_TYPE}/${WORKLOAD_NAME} --context ${CONTEXT} -n ${NAMESPACE} -o json | jq '{spec_replicas: .spec.replicas, ready_replicas: (.status.readyReplicas // 0), available_condition: (.status.conditions[] | select(.type == "Available") | .status // "Unknown")}'
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    timeout_seconds=30
    
    TRY
        ${scale_status}=    Evaluate    json.loads(r'''${scale_check.stdout}''') if r'''${scale_check.stdout}'''.strip() else {}    json
        ${spec_replicas}=    Evaluate    $scale_status.get('spec_replicas', 1)
        
        # DaemonSets don't scale to 0 in the traditional sense, so skip scale-down logic for them
        IF    '${WORKLOAD_TYPE}' == 'daemonset'
            Log    ${WORKLOAD_TYPE} ${WORKLOAD_NAME} is a DaemonSet - proceeding with stacktrace analysis
            Set Suite Variable    ${SKIP_STACKTRACE_CHECKS}    ${False}
        ELSE IF    ${spec_replicas} == 0
            RW.Core.Add Issue
            ...    severity=4
            ...    expected=${WORKLOAD_TYPE} `${WORKLOAD_NAME}` operational status documented
            ...    actual=${WORKLOAD_TYPE} `${WORKLOAD_NAME}` is intentionally scaled to zero replicas
            ...    title=${WORKLOAD_TYPE} `${WORKLOAD_NAME}` is Scaled Down (Informational)
            ...    reproduce_hint=kubectl get ${WORKLOAD_TYPE}/${WORKLOAD_NAME} --context ${CONTEXT} -n ${NAMESPACE} -o yaml
            ...    details=${WORKLOAD_TYPE} `${WORKLOAD_NAME}` is currently scaled to 0 replicas (spec.replicas=0). This is an intentional configuration and not an error. All pod-related healthchecks have been skipped for efficiency. If the workload should be running, scale it up using:\nkubectl scale ${WORKLOAD_TYPE}/${WORKLOAD_NAME} --replicas=<desired_count> --context ${CONTEXT} -n ${NAMESPACE}
            ...    next_steps=This is informational only. If the workload should be running, scale it up.
            
            RW.Core.Add Pre To Report    **ℹ️ ${WORKLOAD_TYPE} `${WORKLOAD_NAME}` is scaled to 0 replicas - Skipping stacktrace analysis**\n**Available Condition:** ${scale_status.get('available_condition', 'Unknown')}
            
            Set Suite Variable    ${SKIP_STACKTRACE_CHECKS}    ${True}
        ELSE
            Set Suite Variable    ${SKIP_STACKTRACE_CHECKS}    ${False}
        END
        
    EXCEPT
        Log    Warning: Failed to check workload scale, continuing with normal checks
        Set Suite Variable    ${SKIP_STACKTRACE_CHECKS}    ${False}
    END


*** Tasks ***
Analyze Workload Stacktraces for ${WORKLOAD_TYPE} `${WORKLOAD_NAME}` in Namespace `${NAMESPACE}`
    [Documentation]    Collects and analyzes stacktraces/tracebacks from all pods in the workload for troubleshooting application issues.
    [Tags]
    ...    logs
    ...    stacktraces
    ...    tracebacks
    ...    workload
    ...    troubleshooting
    ...    errors
    ...    access:read-only
    # Skip pod-related checks if workload is scaled to 0
    IF    not ${SKIP_STACKTRACE_CHECKS}
        # Convert comma-separated string to list for excluded containers
        @{EXCLUDED_CONTAINERS}=    Run Keyword If    "${EXCLUDED_CONTAINER_NAMES}" != ""    Split String    ${EXCLUDED_CONTAINER_NAMES}    ,    ELSE    Create List
        
        # Fetch logs using RW.K8sLog library (same pattern as deployment healthcheck)
        ${log_dir}=    RW.K8sLog.Fetch Workload Logs
        ...    workload_type=${WORKLOAD_TYPE}
        ...    workload_name=${WORKLOAD_NAME}
        ...    namespace=${NAMESPACE}
        ...    context=${CONTEXT}
        ...    kubeconfig=${kubeconfig}
        ...    log_age=${LOG_AGE}
        ...    max_log_lines=${LOG_LINES}
        ...    max_log_bytes=${LOG_SIZE}
        ...    excluded_containers=${EXCLUDED_CONTAINERS}
        
        # Extract stacktraces from the log directory using the traceback library
        ${tracebacks}=    RW.LogAnalysis.ExtractTraceback.Extract Tracebacks
        ...    logs_dir=${log_dir}
        
        # Check total number of tracebacks extracted
        ${total_tracebacks}=    Get Length    ${tracebacks}
        
        IF    ${total_tracebacks} == 0
            # No tracebacks found
            RW.Core.Add Pre To Report    **📋 No Stacktraces Found for ${WORKLOAD_TYPE} `${WORKLOAD_NAME}` in Namespace `${NAMESPACE}`**\n**Log Analysis Period:** ${LOG_AGE}\n**Max Log Lines:** ${LOG_LINES}\n**Max Log Size:** ${LOG_SIZE} bytes\n**Excluded Containers:** ${EXCLUDED_CONTAINER_NAMES}\n\nLog analysis completed successfully with no stacktraces detected.
        ELSE            
            # Stacktraces found - create issues for each one
            ${delimiter}=    Evaluate    '-' * 80
            
            FOR    ${traceback}    IN    @{tracebacks}
                ${stacktrace}=    Set Variable    ${traceback["stacktrace"]}
                ${timestamp}=    Set Variable    ${traceback["timestamp"]}
                RW.Core.Add Issue
                ...    severity=2
                ...    expected=No stacktraces should be present in ${WORKLOAD_TYPE} `${WORKLOAD_NAME}` logs in namespace `${NAMESPACE}`
                ...    actual=Stacktrace detected in ${WORKLOAD_TYPE} `${WORKLOAD_NAME}` logs in namespace `${NAMESPACE}`
                ...    title=Stacktrace Detected in ${WORKLOAD_TYPE} `${WORKLOAD_NAME}`
                ...    reproduce_hint=Check application logs for ${WORKLOAD_TYPE} `${WORKLOAD_NAME}` in namespace `${NAMESPACE}`
                ...    details=${delimiter}\n${stacktrace}\n${delimiter}
                ...    next_steps=Review application logs for the root cause of the stacktrace\nCheck application configuration and resource limits\nInvestigate the specific error conditions that led to this stacktrace\nConsider scaling or restarting the ${WORKLOAD_TYPE} if issues persist\nMonitor application health and performance metrics
                ...    next_action=analyseStacktrace
                ...    observed_at=${timestamp}
            END
            
            # Create consolidated report showing all stacktraces
            ${stacktrace_strings}=    Evaluate    [tb["stacktrace"] for tb in ${tracebacks}]
            ${agg_tracebacks}=    Evaluate    "\\n" + "\\n${delimiter}\\n".join(${stacktrace_strings})
            RW.Core.Add Pre To Report    **🔍 Stacktraces Found for ${WORKLOAD_TYPE} `${WORKLOAD_NAME}` in Namespace `${NAMESPACE}`**\n**Total Stacktraces:** ${total_tracebacks}\n**Log Analysis Period:** ${LOG_AGE}\n**Max Log Lines:** ${LOG_LINES}\n**Max Log Size:** ${LOG_SIZE} bytes\n**Excluded Containers:** ${EXCLUDED_CONTAINER_NAMES}\n\n${agg_tracebacks}
        END
        
        # Clean up temporary log files
        RW.K8sLog.Cleanup Temp Files
    END
