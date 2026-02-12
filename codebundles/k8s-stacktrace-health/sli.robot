*** Settings ***
Metadata          Author    akshayrw25
Documentation     This SLI monitors stacktrace health in kubernetes workload application logs. Produces a value between 0 (stacktraces detected) and 1 (no stacktraces found). Focuses specifically on application error detection through stacktrace analysis.
Metadata          Display Name    Kubernetes Workload Stacktrace Health SLI
Metadata          Supports    Kubernetes,AKS,EKS,GKE,OpenShift
Suite Setup       Suite Initialization
Library           BuiltIn
Library           RW.Core
Library           RW.CLI
Library           RW.platform
Library           RW.LogAnalysis.ExtractTraceback
Library           RW.K8sLog
Library           OperatingSystem
Library           String
Library           Collections

*** Keywords ***
Suite Initialization
    ${kubeconfig}=    RW.Core.Import Secret    kubeconfig
    ...    type=string
    ...    description=The kubernetes kubeconfig yaml containing connection configuration used to connect to cluster(s).
    ...    pattern=\w*
    ...    example=For examples, start here https://kubernetes.io/docs/concepts/configuration/organize-cluster-access-kubeconfig/
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
    ${WORKLOAD_NAME}=    RW.Core.Import User Variable    WORKLOAD_NAME
    ...    type=string
    ...    description=The name of the Kubernetes workload to check for stacktraces.
    ...    pattern=\w*
    ...    example=my-workload
    ${WORKLOAD_TYPE}=    RW.Core.Import User Variable    WORKLOAD_TYPE
    ...    type=string
    ...    description=The type of Kubernetes workload to check.
    ...    pattern=\w*
    ...    enum=[deployment,statefulset,daemonset]
    ...    example=deployment
    ...    default=deployment
    ${RW_LOOKBACK_WINDOW}=    RW.Core.Import Platform Variable    RW_LOOKBACK_WINDOW
    ${RW_LOOKBACK_WINDOW}=    RW.Core.Normalize Lookback Window     ${RW_LOOKBACK_WINDOW}    2 
    ${MAX_LOG_LINES}=    RW.Core.Import User Variable    MAX_LOG_LINES
    ...    type=string
    ...    description=Maximum number of log lines to fetch per container to prevent API overload.
    ...    pattern=^\d+$
    ...    example=100
    ...    default=2000
    ${MAX_LOG_BYTES}=    RW.Core.Import User Variable    MAX_LOG_BYTES
    ...    type=string
    ...    description=Maximum log size in bytes to fetch per container to prevent API overload.
    ...    pattern=^\d+$
    ...    example=256000
    ...    default=256000
    ${EXCLUDED_CONTAINER_NAMES}=    RW.Core.Import User Variable    EXCLUDED_CONTAINER_NAMES
    ...    type=string
    ...    description=Comma-separated list of container names to exclude from log analysis (e.g., linkerd-proxy, istio-proxy, vault-agent).
    ...    pattern=.*
    ...    example=linkerd-proxy,istio-proxy,vault-agent
    ...    default=linkerd-proxy,istio-proxy,vault-agent
    ${KUBERNETES_DISTRIBUTION_BINARY}=    RW.Core.Import User Variable    KUBERNETES_DISTRIBUTION_BINARY
    ...    type=string
    ...    description=Which binary to use for Kubernetes CLI commands.
    ...    enum=[kubectl,oc]
    ...    example=kubectl
    ...    default=kubectl
    Set Suite Variable    ${kubeconfig}    ${kubeconfig}
    Set Suite Variable    ${KUBERNETES_DISTRIBUTION_BINARY}    ${KUBERNETES_DISTRIBUTION_BINARY}
    Set Suite Variable    ${RW_LOOKBACK_WINDOW}    ${RW_LOOKBACK_WINDOW}
    Set Suite Variable    ${MAX_LOG_LINES}    ${MAX_LOG_LINES}
    Set Suite Variable    ${MAX_LOG_BYTES}    ${MAX_LOG_BYTES}
    Set Suite Variable    ${EXCLUDED_CONTAINER_NAMES}    ${EXCLUDED_CONTAINER_NAMES}
    Set Suite Variable    ${CONTEXT}    ${CONTEXT}
    Set Suite Variable    ${NAMESPACE}    ${NAMESPACE}
    Set Suite Variable    ${WORKLOAD_NAME}    ${WORKLOAD_NAME}
    Set Suite Variable    ${WORKLOAD_TYPE}    ${WORKLOAD_TYPE}
    Set Suite Variable    ${env}    {"KUBECONFIG":"./${kubeconfig.key}"}


    # Convert comma-separated string to list
    @{EXCLUDED_CONTAINERS}=    Run Keyword If    "${EXCLUDED_CONTAINER_NAMES}" != ""    Split String    ${EXCLUDED_CONTAINER_NAMES}    ,    ELSE    Create List
    Set Suite Variable    @{EXCLUDED_CONTAINERS}
    
    # Initialize score variables
    Set Suite Variable    ${stacktrace_score}    0
    
    # Check if workload is scaled to 0 and handle appropriately
    # Different workload types have different field structures
    IF    '${WORKLOAD_TYPE}' == 'daemonset'
        ${scale_check}=    RW.CLI.Run Cli
        ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get ${WORKLOAD_TYPE}/${WORKLOAD_NAME} --context ${CONTEXT} -n ${NAMESPACE} -o json | jq '{spec_replicas: .status.desiredNumberScheduled, ready_replicas: (.status.numberReady // 0), available_condition: (.status.conditions[] | select(.type == "Available") | .status // "Unknown")}'
        ...    env=${env}
        ...    secret_file__kubeconfig=${kubeconfig}
        ...    timeout_seconds=30
    ELSE
        # For deployments and statefulsets
        ${scale_check}=    RW.CLI.Run Cli
        ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get ${WORKLOAD_TYPE}/${WORKLOAD_NAME} --context ${CONTEXT} -n ${NAMESPACE} -o json | jq '{spec_replicas: .spec.replicas, ready_replicas: (.status.readyReplicas // 0), available_condition: (.status.conditions[] | select(.type == "Available") | .status // "Unknown")}'
        ...    env=${env}
        ...    secret_file__kubeconfig=${kubeconfig}
        ...    timeout_seconds=30
    END
    
    TRY
        ${scale_status}=    Evaluate    json.loads(r'''${scale_check.stdout}''') if r'''${scale_check.stdout}'''.strip() else {}    json
        ${spec_replicas}=    Evaluate    $scale_status.get('spec_replicas', 1)
        
        # DaemonSets don't scale to 0 in the traditional sense, so skip scale-down logic for them
        IF    '${WORKLOAD_TYPE}' == 'daemonset'
            Log    ${WORKLOAD_TYPE} ${WORKLOAD_NAME} is a DaemonSet - proceeding with stacktrace checks
            Set Suite Variable    ${SKIP_HEALTH_CHECKS}    ${False}
        ELSE IF    ${spec_replicas} == 0
            Log    ${WORKLOAD_TYPE} ${WORKLOAD_NAME} is scaled to 0 replicas - returning perfect health score
            
            # For scaled-down workloads, return a score of 1.0 to indicate "intentionally down" vs "broken"
            Set Suite Variable    ${SKIP_HEALTH_CHECKS}    ${True}
        ELSE
            Log    ${WORKLOAD_TYPE} ${WORKLOAD_NAME} has ${spec_replicas} desired replicas - proceeding with stacktrace checks
            Set Suite Variable    ${SKIP_HEALTH_CHECKS}    ${False}
        END
        
    EXCEPT
        Log    Warning: Failed to check workload scale, continuing with normal stacktrace checks
        Set Suite Variable    ${SKIP_HEALTH_CHECKS}    ${False}
    END



*** Tasks ***
Get Stacktrace Health Score for ${WORKLOAD_TYPE} `${WORKLOAD_NAME}`
    [Documentation]    Checks for recent stacktraces/tracebacks related to the workload within a short time window, with filtering to reduce noise.
    [Tags]    stacktraces    tracebacks    errors    recent    fast    data:logs-stacktrace
    IF    ${SKIP_HEALTH_CHECKS}
        # For scaled-down deployments, return perfect score to indicate "intentionally down" vs "broken"
        ${stacktrace_score}=    Set Variable    1.0
        Set Suite Variable    ${stacktrace_details}     ${WORKLOAD_TYPE} `${WORKLOAD_NAME}` is intentionally scaled to 0 replicas - Score: ${stacktrace_score}
    ELSE
        # Fetch logs using RW.K8sLog library (same pattern as deployment healthcheck)
        ${log_dir}=    RW.K8sLog.Fetch Workload Logs
        ...    workload_type=${WORKLOAD_TYPE}
        ...    workload_name=${WORKLOAD_NAME}
        ...    namespace=${NAMESPACE}
        ...    context=${CONTEXT}
        ...    kubeconfig=${kubeconfig}
        ...    log_age=${RW_LOOKBACK_WINDOW}
        ...    max_log_lines=${MAX_LOG_LINES}
        ...    max_log_bytes=${MAX_LOG_BYTES}
        ...    excluded_containers=${EXCLUDED_CONTAINERS}
        
        # Extract stacktraces from the log directory
        ${recentmost_stacktrace}=    RW.LogAnalysis.ExtractTraceback.Extract Tracebacks
        ...    logs_dir=${log_dir}
        ...    fast_exit=${True}

        ${stacktrace_length}=    Get Length    ${recentmost_stacktrace}
        
        IF    ${stacktrace_length} != 0
            # Stacktrace found - set score to 0
            ${stacktrace_score}=    Set Variable    0
            ${delimiter}=    Evaluate    '-' * 150
            Set Suite Variable    ${stacktrace_details}    **Stacktrace(s) identified**:\n${delimiter}\n${recentmost_stacktrace}\n${delimiter}
        ELSE
            # No stacktraces found - set score to 1
            ${stacktrace_score}=    Set Variable    1.0
            Set Suite Variable    ${stacktrace_details}    **No Stacktraces identified.**\n\nLog analysis completed successfully.
        END
        
        # Clean up temporary log files
        RW.K8sLog.Cleanup Temp Files
    END 

    Set Suite Variable    ${stacktrace_score}
    RW.Core.Push Metric     ${stacktrace_score}   sub_name=stacktrace_score

Generate Stacktrace Health Score for `${WORKLOAD_NAME}`
    [Documentation]    Generates the final stacktrace health score and report details
    [Tags]    score    health    stacktraces
    
    IF    ${SKIP_HEALTH_CHECKS}
        # For scaled-down deployments, return perfect score
        ${health_score}=    Set Variable    1.0
        Log    ${WORKLOAD_TYPE} ${WORKLOAD_NAME} is intentionally scaled to 0 replicas - Score: ${health_score}
        RW.Core.Add to Report    Stacktrace Health Score: ${health_score} - ${WORKLOAD_TYPE} intentionally scaled to 0 replicas
    ELSE
        # Use the stacktrace score as the final health score
        ${health_score}=    Set Variable    ${stacktrace_score}
        
        IF    ${stacktrace_score} == 1.0
            RW.Core.Add to Report    Stacktrace Health Score: ${health_score} - No stacktraces detected in workload logs
        ELSE
            RW.Core.Add to Report    Stacktrace Health Score: ${health_score} - Stacktraces detected in workload logs: ${stacktrace_details}
        END
    END
    
    RW.Core.Push Metric    ${health_score}

