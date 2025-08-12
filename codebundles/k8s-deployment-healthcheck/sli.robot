*** Settings ***
Metadata          Author    stewartshea
Documentation     This SLI uses kubectl to score deployment health. Produces a value between 0 (completely failing the test) and 1 (fully passing the test). Looks for container restarts, critical log errors, pods not ready, deployment status, and recent events.
Metadata          Display Name    Kubernetes Deployment Healthcheck
Metadata          Supports    Kubernetes,AKS,EKS,GKE,OpenShift
Suite Setup       Suite Initialization
Library           BuiltIn
Library           RW.Core
Library           RW.CLI
Library           RW.platform
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
    ${DEPLOYMENT_NAME}=    RW.Core.Import User Variable    DEPLOYMENT_NAME
    ...    type=string
    ...    description=The name of the Kubernetes deployment to check.
    ...    pattern=\w*
    ...    example=my-deployment
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
    ${LOG_AGE}=    RW.Core.Import User Variable    LOG_AGE
    ...    type=string
    ...    description=The time window to fetch logs for analysis.
    ...    pattern=((\d+?)m|(\d+?)h)?
    ...    example=10m
    ...    default=10m
    ${MAX_LOG_LINES}=    RW.Core.Import User Variable    MAX_LOG_LINES
    ...    type=string
    ...    description=Maximum number of log lines to fetch per container to prevent API overload.
    ...    pattern=^\d+$
    ...    example=100
    ...    default=100
    ${MAX_LOG_BYTES}=    RW.Core.Import User Variable    MAX_LOG_BYTES
    ...    type=string
    ...    description=Maximum log size in bytes to fetch per container to prevent API overload.
    ...    pattern=^\d+$
    ...    example=256000
    ...    default=256000
    ${EVENT_AGE}=    RW.Core.Import User Variable    EVENT_AGE
    ...    type=string
    ...    description=The time window to check for recent warning events.
    ...    pattern=((\d+?)m)?
    ...    example=10m
    ...    default=10m
    ${EVENT_THRESHOLD}=    RW.Core.Import User Variable    EVENT_THRESHOLD
    ...    type=string
    ...    description=The maximum number of critical warning events allowed before scoring is reduced.
    ...    pattern=^\d+$
    ...    example=2
    ...    default=2
    ${CHECK_SERVICE_ENDPOINTS}=    RW.Core.Import User Variable    CHECK_SERVICE_ENDPOINTS
    ...    type=string
    ...    description=Whether to check service endpoint health. Set to 'false' if deployment doesn't have associated services.
    ...    enum=[true,false]
    ...    example=true
    ...    default=true
    ${LOGS_EXCLUDE_PATTERN}=    RW.Core.Import User Variable    LOGS_EXCLUDE_PATTERN
    ...    type=string
    ...    description=Pattern used to exclude entries from log analysis when searching for errors. Use regex patterns to filter out false positives like JSON structures.
    ...    pattern=.*
    ...    example="errors":\s*\[\]|"warnings":\s*\[\]
    ...    default="errors":\s*\[\]|\\bINFO\\b|\\bDEBUG\\b|\\bTRACE\\b|\\bSTART\\s*-\\s*|\\bSTART\\s*method\\b
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
    Set Suite Variable    ${LOG_AGE}    ${LOG_AGE}
    Set Suite Variable    ${MAX_LOG_LINES}    ${MAX_LOG_LINES}
    Set Suite Variable    ${MAX_LOG_BYTES}    ${MAX_LOG_BYTES}
    Set Suite Variable    ${EVENT_AGE}    ${EVENT_AGE}
    Set Suite Variable    ${EVENT_THRESHOLD}    ${EVENT_THRESHOLD}
    Set Suite Variable    ${CHECK_SERVICE_ENDPOINTS}    ${CHECK_SERVICE_ENDPOINTS}
    Set Suite Variable    ${LOGS_EXCLUDE_PATTERN}    ${LOGS_EXCLUDE_PATTERN}
    Set Suite Variable    ${CONTEXT}    ${CONTEXT}
    Set Suite Variable    ${NAMESPACE}    ${NAMESPACE}
    Set Suite Variable    ${DEPLOYMENT_NAME}    ${DEPLOYMENT_NAME}
    Set Suite Variable    ${env}    {"KUBECONFIG":"./${kubeconfig.key}"}
    
    # Initialize score variables
    Set Suite Variable    ${container_restart_score}    0
    Set Suite Variable    ${log_health_score}    0
    Set Suite Variable    ${pods_notready_score}    0
    Set Suite Variable    ${replica_score}    0
    Set Suite Variable    ${events_score}    0
    
    # Check if deployment is scaled to 0 and handle appropriately
    ${scale_check}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get deployment/${DEPLOYMENT_NAME} --context ${CONTEXT} -n ${NAMESPACE} -o json | jq '{spec_replicas: .spec.replicas, ready_replicas: (.status.readyReplicas // 0), available_condition: (.status.conditions[] | select(.type == "Available") | .status // "Unknown"), last_scale_time: (.metadata.annotations."deployment.kubernetes.io/last-applied-configuration" // "N/A")}'
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    timeout_seconds=30
    
    TRY
        ${scale_status}=    Evaluate    json.loads(r'''${scale_check.stdout}''') if r'''${scale_check.stdout}'''.strip() else {}    json
        ${spec_replicas}=    Evaluate    $scale_status.get('spec_replicas', 1)
        
        # Try to determine when deployment was scaled down by checking recent events and replica set history
        ${scale_down_info}=    Get Deployment Scale Down Timestamp    ${spec_replicas}
        
        IF    ${spec_replicas} == 0
            Log    ⚠️  Deployment ${DEPLOYMENT_NAME} is scaled to 0 replicas - returning special health score
            Log    📊 Scale down detected at: ${scale_down_info}
            
            # For scaled-down deployments, return a score of 0.5 to indicate "intentionally down" vs "broken"
            Set Suite Variable    ${SKIP_HEALTH_CHECKS}    ${True}
            Set Suite Variable    ${SCALED_DOWN_INFO}    ${scale_down_info}
        ELSE
            Log    ✅ Deployment ${DEPLOYMENT_NAME} has ${spec_replicas} desired replicas - proceeding with health checks
            Set Suite Variable    ${SKIP_HEALTH_CHECKS}    ${False}
        END
        
    EXCEPT
        Log    ⚠️  Warning: Failed to check deployment scale, continuing with normal health checks
        Set Suite Variable    ${SKIP_HEALTH_CHECKS}    ${False}
    END

Get Deployment Scale Down Timestamp
    [Arguments]    ${spec_replicas}
    [Documentation]    Attempts to determine when a deployment was scaled down by examining recent events
    ${scale_down_info}=    Set Variable    Unknown
    
    IF    ${spec_replicas} == 0
        TRY
            # Check recent scaling events to find when it was scaled to 0
            ${scaling_events}=    RW.CLI.Run Cli
            ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get events --context ${CONTEXT} -n ${NAMESPACE} --sort-by='.lastTimestamp' -o json | jq -r '.items[] | select(.reason == "ScalingReplicaSet" and (.message | contains("${DEPLOYMENT_NAME}")) and (.message | contains("to 0"))) | {timestamp: .lastTimestamp, message: .message}' | jq -s 'sort_by(.timestamp) | reverse | .[0] // empty'
            ...    env=${env}
            ...    secret_file__kubeconfig=${kubeconfig}
            ...    timeout_seconds=15
            
            IF    '''${scaling_events.stdout}''' != ''
                ${event_data}=    Evaluate    json.loads(r'''${scaling_events.stdout}''') if r'''${scaling_events.stdout}'''.strip() else {}    json
                ${timestamp}=    Evaluate    $event_data.get('timestamp', 'Unknown')
                ${message}=    Evaluate    $event_data.get('message', 'Unknown')
                ${scale_down_info}=    Set Variable    ${timestamp} (${message})
                Log    📅 Found scale-down event: ${scale_down_info}
            ELSE
                # Try checking replicaset history as fallback
                ${rs_history}=    RW.CLI.Run Cli
                ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get replicasets --context ${CONTEXT} -n ${NAMESPACE} -l app=${DEPLOYMENT_NAME} -o json | jq -r '.items[] | select(.spec.replicas == 0) | {creation_time: .metadata.creationTimestamp, name: .metadata.name}' | jq -s 'sort_by(.creation_time) | reverse | .[0] // empty'
                ...    env=${env}
                ...    secret_file__kubeconfig=${kubeconfig}
                ...    timeout_seconds=15
                
                IF    '''${rs_history.stdout}''' != ''
                    ${rs_data}=    Evaluate    json.loads(r'''${rs_history.stdout}''') if r'''${rs_history.stdout}'''.strip() else {}    json
                    ${rs_time}=    Evaluate    $rs_data.get('creation_time', 'Unknown')
                    ${scale_down_info}=    Set Variable    Likely around ${rs_time} (based on ReplicaSet history)
                    Log    📅 Estimated scale-down time from ReplicaSet: ${scale_down_info}
                ELSE
                    ${scale_down_info}=    Set Variable    Unable to determine - no recent scaling events found
                    Log    ❓ Could not determine when deployment was scaled down
                END
            END
        EXCEPT
            Log    ⚠️  Warning: Failed to determine scale-down timestamp
            ${scale_down_info}=    Set Variable    Failed to determine scale-down time
        END
    END
    
    RETURN    ${scale_down_info}

*** Tasks ***
Get Container Restarts and Score for Deployment `${DEPLOYMENT_NAME}`
    [Documentation]    Counts the total sum of container restarts within a timeframe and determines if they're beyond a threshold.
    [Tags]    Restarts    Pods    Containers    Count    Status
    
    # Skip if deployment is scaled down
    IF    ${SKIP_HEALTH_CHECKS}
        Log    ⏭️  Skipping container restart check - deployment is scaled to 0 replicas
        ${container_restart_score}=    Set Variable    1  # Perfect score for scaled deployment
        Set Suite Variable    ${container_restart_score}
        RW.Core.Push Metric    ${container_restart_score}    sub_name=container_restarts
        RETURN
    END
    
    ${pods}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get pods --context ${CONTEXT} -n ${NAMESPACE} -l app=${DEPLOYMENT_NAME} -o json
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ${CONTAINER_RESTART_AGE}=    RW.CLI.String To Datetime    ${CONTAINER_RESTART_AGE}
    ${container_restarts_sum}=    RW.CLI.Parse Cli Json Output
    ...    rsp=${pods}
    ...    extract_path_to_var__pod_restart_stats=items[].{name:metadata.name, containerRestarts:status.containerStatuses[].{restartCount:restartCount, terminated_at:lastState.terminated.finishedAt}|[?restartCount > `0` && terminated_at >= `${CONTAINER_RESTART_AGE}`]}
    ...    from_var_with_path__pod_restart_stats__to__pods_with_recent_restarts=[].{name: name, restartSum:sum(containerRestarts[].restartCount || [`0`])}|[?restartSum > `0`]
    ...    from_var_with_path__pods_with_recent_restarts__to__restart_sum=sum([].restartSum)
    ...    assign_stdout_from_var=restart_sum
    
    ${restart_count}=    Convert To Integer    ${container_restarts_sum.stdout}
    ${threshold}=    Convert To Integer    ${CONTAINER_RESTART_THRESHOLD}
    ${container_restart_score}=    Evaluate    1 if ${restart_count} <= ${threshold} else 0
    
    # Store details for final score calculation logging
    Set Suite Variable    ${container_restart_details}    ${restart_count} restarts (threshold: ${threshold})
    Set Suite Variable    ${container_restart_score}
    RW.Core.Push Metric    ${container_restart_score}    sub_name=container_restarts

Get Critical Log Errors and Score for Deployment `${DEPLOYMENT_NAME}`
    [Documentation]    Fetches logs and checks for critical error patterns that indicate application failures.
    [Tags]    logs    errors    critical    patterns
    
    # Skip if deployment is scaled down  
    IF    ${SKIP_HEALTH_CHECKS}
        Log    ⏭️  Skipping log analysis - deployment is scaled to 0 replicas
        ${log_health_score}=    Set Variable    1  # Perfect score for scaled deployment
        Set Suite Variable    ${log_health_score}
        RW.Core.Push Metric    ${log_health_score}    sub_name=log_errors
        RETURN
    END
    
    ${log_dir}=    RW.K8sLog.Fetch Workload Logs
    ...    workload_type=deployment
    ...    workload_name=${DEPLOYMENT_NAME}
    ...    namespace=${NAMESPACE}
    ...    context=${CONTEXT}
    ...    kubeconfig=${kubeconfig}
    ...    log_age=${LOG_AGE}
    ...    max_log_lines=${MAX_LOG_LINES}
    ...    max_log_bytes=${MAX_LOG_BYTES}
    
    # Use only critical error patterns for fast SLI checks
    @{critical_categories}=    Create List    GenericError    AppFailure    StackTrace
    
    ${scan_results}=    RW.K8sLog.Scan Logs For Issues
    ...    log_dir=${log_dir}
    ...    workload_type=deployment
    ...    workload_name=${DEPLOYMENT_NAME}
    ...    namespace=${NAMESPACE}
    ...    categories=${critical_categories}
    ...    custom_patterns_file=sli_critical_patterns.json
    
    # Post-process results to filter out patterns matching LOGS_EXCLUDE_PATTERN
    TRY
        IF    "${LOGS_EXCLUDE_PATTERN}" != ""
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

Get NotReady Pods Score for Deployment `${DEPLOYMENT_NAME}`
    [Documentation]    Fetches a count of unready pods for the specific deployment.
    [Tags]    access:read-only    Pods    Status    Phase    Ready    Unready    Running
    
    # Skip if deployment is scaled down
    IF    ${SKIP_HEALTH_CHECKS}
        Log    ⏭️  Skipping pod readiness check - deployment is scaled to 0 replicas  
        ${pods_notready_score}=    Set Variable    1  # Perfect score for scaled deployment
        Set Suite Variable    ${pods_notready_score}
        RW.Core.Push Metric    ${pods_notready_score}    sub_name=pod_readiness
        RETURN
    END
    
    ${unreadypods_results}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get pods --context ${CONTEXT} -n ${NAMESPACE} -l app=${DEPLOYMENT_NAME} -o json | jq -r '.items[] | select(.status.conditions[]? | select(.type == "Ready" and .status == "False" and .reason != "PodCompleted")) | {kind: .kind, name: .metadata.name, conditions: .status.conditions}' | jq -s '. | length' | tr -d '\n'
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    
    ${unready_count}=    Convert To Integer    ${unreadypods_results.stdout}
    ${pods_notready_score}=    Evaluate    1 if ${unready_count} == 0 else 0
    
    # Store details for final score calculation logging
    Set Suite Variable    ${pod_readiness_details}    ${unready_count} unready pods
    Set Suite Variable    ${pods_notready_score}
    RW.Core.Push Metric    ${pods_notready_score}    sub_name=pod_readiness

Get Deployment Replica Status and Score for `${DEPLOYMENT_NAME}`
    [Documentation]    Checks if deployment has the expected number of ready replicas and is available.
    [Tags]    deployment    replicas    status    availability
    
    # Skip if deployment is scaled down
    IF    ${SKIP_HEALTH_CHECKS}
        Log    ⏭️  Skipping replica status check - deployment is scaled to 0 replicas
        ${replica_score}=    Set Variable    1  # Perfect score for scaled deployment  
        Set Suite Variable    ${replica_score}
        RW.Core.Push Metric    ${replica_score}    sub_name=replica_status
        RETURN
    END
    
    ${deployment_status}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get deployment/${DEPLOYMENT_NAME} --context ${CONTEXT} -n ${NAMESPACE} -o json | jq '.status | {ready_replicas: (.readyReplicas // 0), desired_replicas: .replicas, available_condition: (if any(.conditions[]; .type == "Available") then (.conditions[] | select(.type == "Available")) else {"status": "Unknown"} end)}'
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    
    TRY
        ${status_json}=    Evaluate    json.loads(r'''${deployment_status.stdout}''') if r'''${deployment_status.stdout}'''.strip() else {}    json
        ${ready_replicas}=    Evaluate    $status_json.get('ready_replicas', 0)
        ${desired_replicas}=    Evaluate    $status_json.get('desired_replicas', 0)
        ${available_status}=    Evaluate    $status_json.get('available_condition', {}).get('status', 'Unknown')
        
        # Score is 1 if we have at least 1 ready replica and deployment is available
        ${replica_score}=    Evaluate    1 if ${ready_replicas} >= 1 and "${available_status}" == "True" else 0
        
        # Store details for final score calculation logging
        Set Suite Variable    ${replica_details}    ${ready_replicas}/${desired_replicas} ready, available: ${available_status}
    EXCEPT
        ${replica_score}=    Set Variable    0
        Set Suite Variable    ${replica_details}    status parse failed
    END
    
    Set Suite Variable    ${replica_score}
    RW.Core.Push Metric    ${replica_score}    sub_name=replica_status

Get Recent Warning Events Score for `${DEPLOYMENT_NAME}`
    [Documentation]    Checks for recent warning events related to the deployment within a short time window, with filtering to reduce noise.
    [Tags]    events    warnings    recent    fast
    
    # Even for scaled deployments, we should check events as they might indicate issues with scaling
    ${EVENT_AGE}=    RW.CLI.String To Datetime    ${EVENT_AGE}
    ${recent_events}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get events --context ${CONTEXT} -n ${NAMESPACE} -o json | jq '(now - (${EVENT_AGE})) as $time_limit | [ .items[] | select(.type == "Warning" and (.involvedObject.kind == "Deployment" or .involvedObject.kind == "ReplicaSet") and (.involvedObject.name | tostring | contains("${DEPLOYMENT_NAME}")) and (.lastTimestamp | fromdateiso8601) >= $time_limit and (.reason | test("FailedCreate|FailedScheduling|FailedMount|FailedAttachVolume|FailedPull|CrashLoopBackOff|ImagePullBackOff|ErrImagePull|Failed|Error|BackOff"; "i"))) ] | length'
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    
    TRY
        ${event_count}=    Evaluate    int(r'''${recent_events.stdout}''') if r'''${recent_events.stdout}'''.strip() else 0
        ${threshold}=    Convert To Integer    ${EVENT_THRESHOLD}
        ${threshold_doubled}=    Evaluate    ${threshold} * 2
        
        # Use threshold-based scoring instead of binary
        # Score is 1 if events <= threshold, 0.5 if events <= threshold*2, 0 if events > threshold*2
        ${events_score}=    Evaluate    1 if ${event_count} <= ${threshold} else (0.5 if ${event_count} <= ${threshold_doubled} else 0)
        
        # Store details for final score calculation logging
        Set Suite Variable    ${events_details}    ${event_count} events (threshold: ${threshold})
    EXCEPT
        ${events_score}=    Set Variable    1
        Set Suite Variable    ${events_details}    event parse failed
    END
    
    Set Suite Variable    ${events_score}
    RW.Core.Push Metric    ${events_score}    sub_name=warning_events

Generate Deployment Health Score for `${DEPLOYMENT_NAME}`
    @{unhealthy_components}=    Create List
    IF    ${SKIP_HEALTH_CHECKS}
        # For scaled-down deployments, return a specific score (0.5) to distinguish from "broken"
        ${health_score}=    Set Variable    0.5
        Log    Deployment ${DEPLOYMENT_NAME} is intentionally scaled to 0 replicas (${SCALED_DOWN_INFO}) - Score: ${health_score}
    ELSE
        # Calculate the normal health score
        ${active_checks}=    Set Variable    5
        ${deployment_health_score}=    Evaluate    (${container_restart_score} + ${log_health_score} + ${pods_notready_score} + ${replica_score} + ${events_score}) / ${active_checks}
        ${health_score}=    Convert to Number    ${deployment_health_score}    2
        
        # Create a single line showing unhealthy components
        IF    ${container_restart_score} < 1    Append To List    ${unhealthy_components}    Container Restarts (${container_restart_details})
        IF    ${log_health_score} < 0.8    Append To List    ${unhealthy_components}    Log Health (${log_health_details})
        IF    ${pods_notready_score} < 1    Append To List    ${unhealthy_components}    Pod Readiness (${pod_readiness_details})
        IF    ${replica_score} < 1    Append To List    ${unhealthy_components}    Replica Status (${replica_details})
        IF    ${events_score} < 1    Append To List    ${unhealthy_components}    Warning Events (${events_details})
        
        ${unhealthy_count}=    Get Length    ${unhealthy_components}
        IF    ${unhealthy_count} > 0
            ${unhealthy_list}=    Evaluate    ', '.join(@{unhealthy_components})
        ELSE
            ${unhealthy_list}=    Set Variable    "None"
            Log    Health Score: ${health_score} - All components healthy
        END
    END
    RW.Core.Add to Report    Health Score: ${health_score} - Unhealthy components: ${unhealthy_list}
    RW.Core.Push Metric    ${health_score} 