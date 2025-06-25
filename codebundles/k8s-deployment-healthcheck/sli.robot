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

*** Tasks ***
Get Container Restarts and Score for Deployment `${DEPLOYMENT_NAME}`
    [Documentation]    Counts the total sum of container restarts within a timeframe and determines if they're beyond a threshold.
    [Tags]    Restarts    Pods    Containers    Count    Status
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
    Log    ${container_restarts_sum.stdout} total container restarts found in the last ${CONTAINER_RESTART_AGE}
    ${container_restart_score}=    Evaluate    1 if ${container_restarts_sum.stdout} <= ${CONTAINER_RESTART_THRESHOLD} else 0
    Set Suite Variable    ${container_restart_score}

Get Critical Log Errors and Score for Deployment `${DEPLOYMENT_NAME}`
    [Documentation]    Fetches logs and checks for critical error patterns that indicate application failures.
    [Tags]    logs    errors    critical    patterns
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
    
    ${log_health_score}=    RW.K8sLog.Calculate Log Health Score    scan_results=${scan_results}
    Set Suite Variable    ${log_health_score}
    
    RW.K8sLog.Cleanup Temp Files

Get NotReady Pods Score for Deployment `${DEPLOYMENT_NAME}`
    [Documentation]    Fetches a count of unready pods for the specific deployment.
    [Tags]    access:read-only    Pods    Status    Phase    Ready    Unready    Running
    ${unreadypods_results}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get pods --context ${CONTEXT} -n ${NAMESPACE} -l app=${DEPLOYMENT_NAME} -o json | jq -r '.items[] | select(.status.conditions[]? | select(.type == "Ready" and .status == "False" and .reason != "PodCompleted")) | {kind: .kind, name: .metadata.name, conditions: .status.conditions}' | jq -s '. | length' | tr -d '\n'
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    Log    ${unreadypods_results.stdout} total unready pods for deployment ${DEPLOYMENT_NAME}
    ${pods_notready_score}=    Evaluate    1 if ${unreadypods_results.stdout} == 0 else 0
    Set Suite Variable    ${pods_notready_score}

Get Deployment Replica Status and Score for `${DEPLOYMENT_NAME}`
    [Documentation]    Checks if deployment has the expected number of ready replicas and is available.
    [Tags]    deployment    replicas    status    availability
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
        Log    Deployment ${DEPLOYMENT_NAME}: ${ready_replicas}/${desired_replicas} ready replicas, available: ${available_status}
    EXCEPT
        Log    Warning: Failed to parse deployment status, assuming unhealthy
        ${replica_score}=    0
    END
    
    Set Suite Variable    ${replica_score}

Get Recent Warning Events Score for `${DEPLOYMENT_NAME}`
    [Documentation]    Checks for recent warning events related to the deployment within a short time window, with filtering to reduce noise.
    [Tags]    events    warnings    recent    fast
    ${EVENT_AGE}=    RW.CLI.String To Datetime    ${EVENT_AGE}
    ${recent_events}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get events --context ${CONTEXT} -n ${NAMESPACE} -o json | jq '(now - (${EVENT_AGE})) as $time_limit | [ .items[] | select(.type == "Warning" and (.involvedObject.kind == "Deployment" or .involvedObject.kind == "ReplicaSet") and (.involvedObject.name | tostring | contains("${DEPLOYMENT_NAME}")) and (.lastTimestamp | fromdateiso8601) >= $time_limit and (.reason | test("FailedCreate|FailedScheduling|FailedMount|FailedAttachVolume|FailedPull|CrashLoopBackOff|ImagePullBackOff|ErrImagePull|Failed|Error|BackOff"; "i"))) ] | length'
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    
    TRY
        ${event_count}=    Evaluate    int(r'''${recent_events.stdout}''') if r'''${recent_events.stdout}'''.strip() else 0
        Log    ${event_count} critical warning events found for deployment ${DEPLOYMENT_NAME} in last ${EVENT_AGE}
        
        # Use threshold-based scoring instead of binary
        # Score is 1 if events <= threshold, 0.5 if events <= threshold*2, 0 if events > threshold*2
        ${threshold_doubled}=    Evaluate    ${EVENT_THRESHOLD} * 2
        ${events_score}=    Evaluate    1 if ${event_count} <= ${EVENT_THRESHOLD} else (0.5 if ${event_count} <= ${threshold_doubled} else 0)
    EXCEPT
        Log    Warning: Failed to parse events count, assuming healthy
        ${events_score}=    1
    END
    
    Set Suite Variable    ${events_score}

Generate Deployment Health Score for `${DEPLOYMENT_NAME}`
    # Calculate the number of active checks (now always 5)
    ${active_checks}=    Set Variable    5
    ${deployment_health_score}=    Evaluate    (${container_restart_score} + ${log_health_score} + ${pods_notready_score} + ${replica_score} + ${events_score}) / ${active_checks}
    ${health_score}=    Convert to Number    ${deployment_health_score}    2
    RW.Core.Push Metric    ${health_score} 