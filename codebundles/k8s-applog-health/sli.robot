*** Settings ***
Metadata          Author    akshayrw25
Documentation     This SLI uses kubectl to score application log health. Produces a value between 0 (completely failing the test) and 1 (fully passing the test). Looks for container restarts, critical log errors, pods not ready, deployment status, stacktraces and other recent events.
Metadata          Display Name    Kubernetes Application Log Healthcheck
Metadata          Supports    Kubernetes,AKS,EKS,GKE,OpenShift
Suite Setup       Suite Initialization
Library           BuiltIn
Library           RW.Core
Library           RW.CLI
Library           RW.platform
Library           RW.K8sLog
Library           RW.LogAnalysis.ExtractTraceback

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
    ${WORKLOAD_TYPE}=    RW.Core.Import User Variable    WORKLOAD_TYPE
    ...    type=string
    ...    description=The type of Kubernetes workload to analyze.
    ...    pattern=\w*
    ...    enum=[deployment,statefulset,daemonset]
    ...    example=deployment
    ...    default=deployment
    ${WORKLOAD_NAME}=    RW.Core.Import User Variable    WORKLOAD_NAME
    ...    type=string
    ...    description=The name of the Kubernetes workload to check.
    ...    pattern=\w*
    ...    example=my-workload
    ${CONTAINER_RESTART_AGE}=    RW.Core.Import User Variable    CONTAINER_RESTART_AGE
    ...    type=string
    ...    description=The time window in minutes to search for container restarts.
    ...    pattern=((\d+?)m)?
    ...    example=10m
    ...    default=10m
    ${CONTAINER_RESTART_THRESHOLD}=    RW.Core.Import User Variable    CONTAINER_RESTART_THRESHOLD
    ...    type=string
    ...    description=The maximum total container restarts to be still considered healthy.
    ...    pattern=^\d+$
    ...    example=1
    ...    default=1
    ${RW_LOOKBACK_WINDOW}=    RW.Core.Import Platform Variable    RW_LOOKBACK_WINDOW
    ${RW_LOOKBACK_WINDOW}=    RW.Core.Normalize Lookback Window     ${RW_LOOKBACK_WINDOW}     2 
    ${MAX_LOG_LINES}=    RW.Core.Import User Variable    MAX_LOG_LINES
    ...    type=string
    ...    description=Maximum number of log lines to fetch per container to prevent API overload.
    ...    pattern=^\d+$
    ...    example=100
    ...    default=1000
    ${MAX_LOG_BYTES}=    RW.Core.Import User Variable    MAX_LOG_BYTES
    ...    type=string
    ...    description=Maximum log size in bytes to fetch per container to prevent API overload.
    ...    pattern=^\d+$
    ...    example=256000
    ...    default=256000
    ${LOGS_EXCLUDE_PATTERN}=    RW.Core.Import User Variable    LOGS_EXCLUDE_PATTERN
    ...    type=string
    ...    description=Pattern used to exclude entries from log analysis when searching for errors. Use regex patterns to filter out false positives like JSON structures.
    ...    pattern=.*
    ...    example="errors":\\s*\\[\\]|"warnings":\\s*\\[\\]
    ...    default="errors":\\\\s*\\\\[\\\\]|\\\\bINFO\\\\b|\\\\bDEBUG\\\\b|\\\\bTRACE\\\\b|\\\\bSTART\\\\s*-\\\\s*|\\\\bSTART\\\\s*method\\\\b
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
    Set Suite Variable    ${CONTAINER_RESTART_AGE}    ${CONTAINER_RESTART_AGE}
    Set Suite Variable    ${CONTAINER_RESTART_THRESHOLD}    ${CONTAINER_RESTART_THRESHOLD}
    Set Suite Variable    ${RW_LOOKBACK_WINDOW}    ${RW_LOOKBACK_WINDOW}
    Set Suite Variable    ${MAX_LOG_LINES}    ${MAX_LOG_LINES}
    Set Suite Variable    ${MAX_LOG_BYTES}    ${MAX_LOG_BYTES}
    Set Suite Variable    ${LOGS_EXCLUDE_PATTERN}    ${LOGS_EXCLUDE_PATTERN}
    Set Suite Variable    ${EXCLUDED_CONTAINER_NAMES}    ${EXCLUDED_CONTAINER_NAMES}
    
    # Convert comma-separated string to list
    @{EXCLUDED_CONTAINERS_RAW}=    Run Keyword If    "${EXCLUDED_CONTAINER_NAMES}" != ""    Split String    ${EXCLUDED_CONTAINER_NAMES}    ,    ELSE    Create List
    @{EXCLUDED_CONTAINERS}=    Create List
    FOR    ${container}    IN    @{EXCLUDED_CONTAINERS_RAW}
        ${trimmed_container}=    Strip String    ${container}
        Append To List    ${EXCLUDED_CONTAINERS}    ${trimmed_container}
    END
    Set Suite Variable    @{EXCLUDED_CONTAINERS}

    Set Suite Variable    ${CONTEXT}    ${CONTEXT}
    Set Suite Variable    ${NAMESPACE}    ${NAMESPACE}
    Set Suite Variable    ${WORKLOAD_NAME}    ${WORKLOAD_NAME}
    Set Suite Variable    ${WORKLOAD_TYPE}    ${WORKLOAD_TYPE}
    Set Suite Variable    ${env}    {"KUBECONFIG":"./${kubeconfig.key}"}
    
    # Initialize score variables
    Set Suite Variable    ${container_restart_score}    0
    Set Suite Variable    ${log_health_score}    0
    Set Suite Variable    ${pods_notready_score}    0
    Set Suite Variable    ${replica_score}    0
    Set Suite Variable    ${events_score}    0

    
    # Check if workload is scaled to 0 and handle appropriately
    # Different workload types have different field structures
    
    IF    '${WORKLOAD_TYPE}' == 'daemonset'
        # DaemonSets don't scale to 0 in the traditional sense, so skip scale-down logic for them
        Log    ${WORKLOAD_TYPE} ${WORKLOAD_NAME} is a DaemonSet - proceeding with log checks
        Set Suite Variable    ${SKIP_HEALTH_CHECKS}    ${False}
    ELSE
        IF    '${WORKLOAD_TYPE}' == 'statefulset'
            # StatefulSet: use current/updated replicas in addition to spec/ready
            ${scale_check}=    RW.CLI.Run Cli
            ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get ${WORKLOAD_TYPE}/${WORKLOAD_NAME} --context ${CONTEXT} -n ${NAMESPACE} -o json | jq '{spec_replicas: .spec.replicas, ready_replicas: (.status.readyReplicas // 0), current_replicas: (.status.currentReplicas // 0), updated_replicas: (.status.updatedReplicas // 0)}'
            ...    env=${env}
            ...    secret_file__kubeconfig=${kubeconfig}
            ...    timeout_seconds=30
        ELSE
            # For deployments
            ${scale_check}=    RW.CLI.Run Cli
            ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get ${WORKLOAD_TYPE}/${WORKLOAD_NAME} --context ${CONTEXT} -n ${NAMESPACE} -o json | jq '{spec_replicas: .spec.replicas, ready_replicas: (.status.readyReplicas // 0), available_condition: (.status.conditions[] | select(.type == "Available") | .status // "Unknown")}'
            ...    env=${env}
            ...    secret_file__kubeconfig=${kubeconfig}
            ...    timeout_seconds=30
        END
        
        TRY
            ${scale_status}=    Evaluate    json.loads(r'''${scale_check.stdout}''') if r'''${scale_check.stdout}'''.strip() else {}    json
            ${spec_replicas}=    Evaluate    $scale_status.get('spec_replicas', 1)

            # Try to determine when deployment was scaled down by checking recent events and replica set history
            ${scale_down_info}=    Get Deployment Scale Down Timestamp    ${spec_replicas}
            
            IF    ${spec_replicas} == 0
                Log    ${WORKLOAD_TYPE} ${WORKLOAD_NAME} is scaled to 0 replicas - returning special health score
                Log    Scale down detected at: ${scale_down_info}
                
                # For scaled-down workloads, return a score of 1.0 to indicate "intentionally down" vs "broken"
                Set Suite Variable    ${SKIP_HEALTH_CHECKS}    ${True}
                Set Suite Variable    ${SCALED_DOWN_INFO}    ${scale_down_info}
            ELSE
                Log    ${WORKLOAD_TYPE} ${WORKLOAD_NAME} has ${spec_replicas} desired replicas - proceeding with log checks
                Set Suite Variable    ${SKIP_HEALTH_CHECKS}    ${False}
            END
            
        EXCEPT
            Log    Warning: Failed to check workload scale, continuing with normal log checks
            Set Suite Variable    ${SKIP_HEALTH_CHECKS}    ${False}
        END
    END

Get Deployment Scale Down Timestamp
    [Arguments]    ${spec_replicas}
    [Documentation]    Attempts to determine when a deployment was scaled down by examining recent events
    ${scale_down_info}=    Set Variable    Unknown
    
    IF    ${spec_replicas} == 0
        IF    '${WORKLOAD_TYPE}' == 'deployment'
            TRY
                # Check recent scaling events to find when it was scaled to 0
                ${scaling_events}=    RW.CLI.Run Cli
                ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get events --context ${CONTEXT} -n ${NAMESPACE} --sort-by='.lastTimestamp' -o json | jq -r '.items[] | select(.reason == "ScalingReplicaSet" and (.message | contains("${WORKLOAD_NAME}")) and (.message | contains("to 0"))) | {timestamp: .lastTimestamp, message: .message}' | jq -s 'sort_by(.timestamp) | reverse | .[0] // empty'
                ...    env=${env}
                ...    secret_file__kubeconfig=${kubeconfig}
                ...    timeout_seconds=15
                
                IF    '''${scaling_events.stdout}''' != ''
                    ${event_data}=    Evaluate    json.loads(r'''${scaling_events.stdout}''') if r'''${scaling_events.stdout}'''.strip() else {}    json
                    ${timestamp}=    Evaluate    $event_data.get('timestamp', 'Unknown')
                    ${message}=    Evaluate    $event_data.get('message', 'Unknown')
                    ${scale_down_info}=    Set Variable    ${timestamp} (${message})
                    Log    Found scale-down event: ${scale_down_info}
                ELSE
                    # Try checking replicaset history as fallback
                    ${rs_history}=    RW.CLI.Run Cli
                    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get replicasets --context ${CONTEXT} -n ${NAMESPACE} -l app=${WORKLOAD_NAME} -o json | jq -r '.items[] | select(.spec.replicas == 0) | {creation_time: .metadata.creationTimestamp, name: .metadata.name}' | jq -s 'sort_by(.creation_time) | reverse | .[0] // empty'
                    ...    env=${env}
                    ...    secret_file__kubeconfig=${kubeconfig}
                    ...    timeout_seconds=15
                    
                    IF    '''${rs_history.stdout}''' != ''
                        ${rs_data}=    Evaluate    json.loads(r'''${rs_history.stdout}''') if r'''${rs_history.stdout}'''.strip() else {}    json
                        ${rs_time}=    Evaluate    $rs_data.get('creation_time', 'Unknown')
                        ${scale_down_info}=    Set Variable    Likely around ${rs_time} (based on ReplicaSet history)
                        Log    Estimated scale-down time from ReplicaSet: ${scale_down_info}
                    ELSE
                        ${scale_down_info}=    Set Variable    Unable to determine - no recent scaling events found
                        Log    Could not determine when ${WORKLOAD_TYPE} ${WORKLOAD_NAME} was scaled down
                    END
                END
            EXCEPT
                Log    Warning: Failed to determine scale-down timestamp
                ${scale_down_info}=    Set Variable    Failed to determine scale-down time
            END
        ELSE IF    '${WORKLOAD_TYPE}' == 'statefulset'
            TRY
                # StatefulSet: find scale-to-0 event via involvedObject
                ${scaling_events}=    RW.CLI.Run Cli
                ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get events --context ${CONTEXT} -n ${NAMESPACE} --sort-by='.lastTimestamp' -o json | jq -r '.items[] | select(.involvedObject.kind == "StatefulSet" and .involvedObject.name == "${WORKLOAD_NAME}" and (.message | contains("to 0") or (contains("delete Pod") and contains("successful")))) | {timestamp: .lastTimestamp, message: .message}' | jq -s 'sort_by(.timestamp) | reverse | .[0] // empty'
                ...    env=${env}
                ...    secret_file__kubeconfig=${kubeconfig}
                ...    timeout_seconds=15
                
                IF    '''${scaling_events.stdout}''' != ''
                    ${event_data}=    Evaluate    json.loads(r'''${scaling_events.stdout}''') if r'''${scaling_events.stdout}'''.strip() else {}    json
                    ${timestamp}=    Evaluate    $event_data.get('timestamp', 'Unknown')
                    ${message}=    Evaluate    $event_data.get('message', 'Unknown')
                    ${scale_down_info}=    Set Variable    ${timestamp} (${message})
                    Log    Found scale-down event: ${scale_down_info}
                ELSE
                    ${scale_down_info}=    Set Variable    Unable to determine - no recent scaling events found for StatefulSet
                    Log    Could not determine when ${WORKLOAD_TYPE} ${WORKLOAD_NAME} was scaled down
                END
            EXCEPT
                Log    Warning: Failed to determine scale-down timestamp for StatefulSet
                ${scale_down_info}=    Set Variable    Failed to determine scale-down time
            END
        END
    END

    RETURN    ${scale_down_info}

*** Tasks ***
Get Critical Log Errors and Score for ${WORKLOAD_TYPE} `${WORKLOAD_NAME}`
    [Documentation]    Fetches logs and checks for critical error patterns that indicate application failures.
    [Tags]    logs    errors    critical    patterns
    
    # Skip if deployment is scaled down  
    IF    ${SKIP_HEALTH_CHECKS}
        Log    Skipping log analysis - ${WORKLOAD_TYPE} ${WORKLOAD_NAME} is scaled to 0 replicas
        ${log_health_score}=    Set Variable    1  # Perfect score for scaled deployment
        Set Suite Variable    ${log_health_score}
        RW.Core.Push Metric    ${log_health_score}    sub_name=log_errors
    ELSE
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
                
        # Use only critical error patterns for fast SLI checks
        @{critical_categories}=    Create List    GenericError    AppFailure
        
        ${scan_results}=    RW.K8sLog.Scan Logs For Issues
        ...    log_dir=${log_dir}
        ...    workload_type=${WORKLOAD_TYPE}
        ...    workload_name=${WORKLOAD_NAME}
        ...    namespace=${NAMESPACE}
        ...    categories=${critical_categories}
        ...    custom_patterns_file=sli_critical_patterns.json
        ...    excluded_containers=${EXCLUDED_CONTAINERS}
        
        # Post-process results to filter out patterns matching LOGS_EXCLUDE_PATTERN
        TRY
            IF    $LOGS_EXCLUDE_PATTERN != ""
                ${filtered_issues}=    Evaluate    [issue for issue in $scan_results.get('issues', []) if not __import__('re').search('${LOGS_EXCLUDE_PATTERN}', issue.get('details', ''), __import__('re').IGNORECASE)]    modules=re
                ${filtered_results}=    Evaluate    {**$scan_results, 'issues': $filtered_issues}
                Set Test Variable    ${scan_results}    ${filtered_results}
            END
        EXCEPT
            Log    Warning: Failed to apply LOGS_EXCLUDE_PATTERN filter, using unfiltered results
        END
        
        ${log_health_score}=    RW.K8sLog.Calculate Log Health Score    scan_results=${scan_results}
        
        # Store details for final score calculation logging
        TRY
            ${issues}=    Evaluate    $scan_results.get('issues', [])
            ${issue_count}=    Get Length    ${issues}
            Set Suite Variable    ${log_health_details}    ${issue_count} issues found
        EXCEPT
            Set Suite Variable    ${log_health_details}    analysis completed
        END
        
        Set Suite Variable    ${log_health_score}
        RW.K8sLog.Cleanup Temp Files
        RW.Core.Push Metric    ${log_health_score}    sub_name=log_errors
    END

Get Stacktrace Health Score for ${WORKLOAD_TYPE} `${WORKLOAD_NAME}`
    [Documentation]    Checks for recent stacktraces/tracebacks related to the workload within a short time window, with filtering to reduce noise.
    [Tags]    stacktraces    tracebacks    errors    recent    fast
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

Generate Application Health Score for `${WORKLOAD_TYPE}` `${WORKLOAD_NAME}`
    [Documentation]    Generates the final applog health score and report details
    [Tags]    score    health    applog
    
    IF    ${SKIP_HEALTH_CHECKS}
        # For scaled-down deployments, return perfect score to indicate "intentionally down" vs "broken"
        # We distinguish scaled-down vs broken deployments through the log message and report details
        ${health_score}=    Set Variable    1.0
        Log    ${WORKLOAD_TYPE} ${WORKLOAD_NAME} is intentionally scaled to 0 replicas (${SCALED_DOWN_INFO}) - Score: ${health_score}
    ELSE
        # Use the log health score as the final health score.
        ${health_score}=    Set Variable    min(${log_health_score}, ${stacktrace_score})
        
        IF    ${health_score} == 1.0
            RW.Core.Add to Report    Applog Health Score: ${health_score} - No applog issues or stacktraces detected in workload logs
        ELSE
            RW.Core.Add to Report    Applog Health Score: ${health_score} - Applog issue(s) or stacktrace(s) detected in workload logs: ${log_health_details}
        END
    END
    RW.Core.Push Metric    ${health_score}