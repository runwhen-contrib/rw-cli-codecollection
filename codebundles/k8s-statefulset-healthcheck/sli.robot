*** Settings ***
Metadata          Author    stewartshea
Documentation     This SLI uses kubectl to score StatefulSet health. Produces a value between 0 (completely failing the test) and 1 (fully passing the test). Looks for container restarts, critical log errors, pods not ready, StatefulSet replica/revision status, PersistentVolumeClaim binding, and recent warning events.
Metadata          Display Name    Kubernetes StatefulSet Healthcheck
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
    ${STATEFULSET_NAME}=    RW.Core.Import User Variable    STATEFULSET_NAME
    ...    type=string
    ...    description=The name of the Kubernetes StatefulSet to check.
    ...    pattern=\w*
    ...    example=my-statefulset
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
    ${LOGS_EXCLUDE_PATTERN}=    RW.Core.Import User Variable    LOGS_EXCLUDE_PATTERN
    ...    type=string
    ...    description=Pattern used to exclude entries from log analysis when searching for errors. Use regex patterns to filter out false positives like JSON structures.
    ...    pattern=.*
    ...    example="errors":\s*\[\]|"warnings":\s*\[\]
    ...    default="errors":\s*\[\]|\\bINFO\\b|\\bDEBUG\\b|\\bTRACE\\b|\\bSTART\\s*-\\s*|\\bSTART\\s*method\\b
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
    Set Suite Variable    ${EVENT_AGE}    ${EVENT_AGE}
    Set Suite Variable    ${EVENT_THRESHOLD}    ${EVENT_THRESHOLD}
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
    Set Suite Variable    ${STATEFULSET_NAME}    ${STATEFULSET_NAME}
    Set Suite Variable    ${env}    {"KUBECONFIG":"./${kubeconfig.key}"}

    # Initialize score variables
    Set Suite Variable    ${container_restart_score}    0
    Set Suite Variable    ${log_health_score}    0
    Set Suite Variable    ${pods_notready_score}    0
    Set Suite Variable    ${replica_score}    0
    Set Suite Variable    ${pvc_score}    0
    Set Suite Variable    ${events_score}    0

    # Initialize details so the final report always has a value to reference
    Set Suite Variable    ${container_restart_details}    0 restarts (threshold: ${CONTAINER_RESTART_THRESHOLD})
    Set Suite Variable    ${log_health_details}    analysis skipped
    Set Suite Variable    ${pod_readiness_details}    0 unready pods
    Set Suite Variable    ${replica_details}    0/0 ready
    Set Suite Variable    ${pvc_details}    0/0 bound
    Set Suite Variable    ${events_details}    0 events (threshold: ${EVENT_THRESHOLD})

    # Resolve the StatefulSet's pod label selector once so all checks share it.
    ${selector_query}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get statefulset ${STATEFULSET_NAME} --context ${CONTEXT} -n ${NAMESPACE} -o json | jq -r '.spec.selector.matchLabels | to_entries | map("\\(.key)=\\(.value)") | join(",")'
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    timeout_seconds=30
    ${statefulset_selector}=    Strip String    ${selector_query.stdout}
    IF    "${statefulset_selector}" == ""
        ${statefulset_selector}=    Set Variable    app=${STATEFULSET_NAME}
    END
    Set Suite Variable    ${STATEFULSET_SELECTOR}    ${statefulset_selector}

    # Check if StatefulSet is scaled to 0 and handle appropriately
    ${scale_check}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get statefulset/${STATEFULSET_NAME} --context ${CONTEXT} -n ${NAMESPACE} -o json | jq '{spec_replicas: .spec.replicas, ready_replicas: (.status.readyReplicas // 0), current_replicas: (.status.currentReplicas // 0), updated_replicas: (.status.updatedReplicas // 0), current_revision: .status.currentRevision, update_revision: .status.updateRevision}'
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    timeout_seconds=30

    TRY
        ${scale_status}=    Evaluate    json.loads(r'''${scale_check.stdout}''') if r'''${scale_check.stdout}'''.strip() else {}    json
        ${spec_replicas}=    Evaluate    $scale_status.get('spec_replicas', 1)

        # Try to determine when StatefulSet was scaled down
        ${scale_down_info}=    Get StatefulSet Scale Down Timestamp    ${spec_replicas}

        IF    ${spec_replicas} == 0
            Log    StatefulSet ${STATEFULSET_NAME} is scaled to 0 replicas - returning special health score
            Log    Scale down detected at: ${scale_down_info}
            Set Suite Variable    ${SKIP_HEALTH_CHECKS}    ${True}
            Set Suite Variable    ${SCALED_DOWN_INFO}    ${scale_down_info}
        ELSE
            Log    StatefulSet ${STATEFULSET_NAME} has ${spec_replicas} desired replicas - proceeding with health checks
            Set Suite Variable    ${SKIP_HEALTH_CHECKS}    ${False}
        END

    EXCEPT
        Log    Warning: Failed to check StatefulSet scale, continuing with normal health checks
        Set Suite Variable    ${SKIP_HEALTH_CHECKS}    ${False}
    END

Convert Duration To Seconds
    [Arguments]    ${duration}    ${default_seconds}=600
    [Documentation]    Converts a short duration string like "10m", "1h", "30s", or "1d" into an integer number of seconds. Falls back to ${default_seconds} on parse failure. A bare integer is interpreted as minutes to match the historical pattern used by these SLIs.
    ${seconds}=    Evaluate
    ...    (lambda m: (int(m.group(1)) * {'s': 1, 'm': 60, 'h': 3600, 'd': 86400}[m.group(2) or 'm']) if m else ${default_seconds})(__import__('re').match(r'^\\s*(\\d+)\\s*([smhd]?)\\s*$', '${duration}'))
    RETURN    ${seconds}

Get StatefulSet Scale Down Timestamp
    [Arguments]    ${spec_replicas}
    [Documentation]    Attempts to determine when a StatefulSet was scaled down by examining recent events
    ${scale_down_info}=    Set Variable    Unknown

    IF    ${spec_replicas} == 0
        TRY
            # Check recent scaling events to find when it was scaled to 0
            ${scaling_events}=    RW.CLI.Run Cli
            ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get events --context ${CONTEXT} -n ${NAMESPACE} --sort-by='.lastTimestamp' -o json | jq -r '.items[] | select((.reason == "SuccessfulDelete" or .reason == "ScalingReplicaSet") and (.involvedObject.kind == "StatefulSet") and (.involvedObject.name == "${STATEFULSET_NAME}")) | {timestamp: .lastTimestamp, message: .message}' | jq -s 'sort_by(.timestamp) | reverse | .[0] // empty'
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
                ${scale_down_info}=    Set Variable    Unable to determine - no recent scaling events found
                Log    Could not determine when StatefulSet was scaled down
            END
        EXCEPT
            Log    Warning: Failed to determine scale-down timestamp
            ${scale_down_info}=    Set Variable    Failed to determine scale-down time
        END
    END

    RETURN    ${scale_down_info}

*** Tasks ***
Get Container Restarts and Score for StatefulSet `${STATEFULSET_NAME}`
    [Documentation]    Counts the total sum of container restarts within a timeframe and determines if they're beyond a threshold.
    [Tags]    Restarts    Pods    Containers    Count    Status    data:config

    # Skip if StatefulSet is scaled down
    IF    ${SKIP_HEALTH_CHECKS}
        Log    Skipping container restart check - StatefulSet is scaled to 0 replicas
        ${container_restart_score}=    Set Variable    1
        Set Suite Variable    ${container_restart_score}
        RW.Core.Push Metric    ${container_restart_score}    sub_name=container_restarts
    ELSE
        ${pods}=    RW.CLI.Run Cli
        ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get pods --context ${CONTEXT} -n ${NAMESPACE} -l ${STATEFULSET_SELECTOR} -o json
        ...    env=${env}
        ...    secret_file__kubeconfig=${kubeconfig}
        ${CONTAINER_RESTART_AGE_DT}=    RW.CLI.String To Datetime    ${CONTAINER_RESTART_AGE}
        ${container_restarts_sum}=    RW.CLI.Parse Cli Json Output
        ...    rsp=${pods}
        ...    extract_path_to_var__pod_restart_stats=items[].{name:metadata.name, containerRestarts:status.containerStatuses[].{restartCount:restartCount, terminated_at:lastState.terminated.finishedAt}|[?restartCount > `0` && terminated_at >= `${CONTAINER_RESTART_AGE_DT}`]}
        ...    from_var_with_path__pod_restart_stats__to__pods_with_recent_restarts=[].{name: name, restartSum:sum(containerRestarts[].restartCount || [`0`])}|[?restartSum > `0`]
        ...    from_var_with_path__pods_with_recent_restarts__to__restart_sum=sum([].restartSum)
        ...    assign_stdout_from_var=restart_sum

        ${restart_count}=    Convert To Integer    ${container_restarts_sum.stdout}
        ${threshold}=    Convert To Integer    ${CONTAINER_RESTART_THRESHOLD}
        ${container_restart_score}=    Evaluate    1 if ${restart_count} <= ${threshold} else 0

        Set Suite Variable    ${container_restart_details}    ${restart_count} restarts (threshold: ${threshold})
        Set Suite Variable    ${container_restart_score}
        RW.Core.Push Metric    ${container_restart_score}    sub_name=container_restarts
    END

Get Critical Log Errors and Score for StatefulSet `${STATEFULSET_NAME}`
    [Documentation]    Fetches logs and checks for critical error patterns that indicate application failures.
    [Tags]    logs    errors    critical    patterns    data:logs-regexp

    # Skip if StatefulSet is scaled down
    IF    ${SKIP_HEALTH_CHECKS}
        Log    Skipping log analysis - StatefulSet is scaled to 0 replicas
        ${log_health_score}=    Set Variable    1
        Set Suite Variable    ${log_health_score}
        RW.Core.Push Metric    ${log_health_score}    sub_name=log_errors
    ELSE
        ${log_dir}=    RW.K8sLog.Fetch Workload Logs
        ...    workload_type=statefulset
        ...    workload_name=${STATEFULSET_NAME}
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
        ...    workload_type=statefulset
        ...    workload_name=${STATEFULSET_NAME}
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

Get NotReady Pods Score for StatefulSet `${STATEFULSET_NAME}`
    [Documentation]    Fetches a count of unready pods for the specific StatefulSet.
    [Tags]    access:read-only    Pods    Status    Phase    Ready    Unready    Running    data:config

    # Skip if StatefulSet is scaled down
    IF    ${SKIP_HEALTH_CHECKS}
        Log    Skipping pod readiness check - StatefulSet is scaled to 0 replicas
        ${pods_notready_score}=    Set Variable    1
        Set Suite Variable    ${pods_notready_score}
        RW.Core.Push Metric    ${pods_notready_score}    sub_name=pod_readiness
    ELSE
        ${unreadypods_results}=    RW.CLI.Run Cli
        ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get pods --context ${CONTEXT} -n ${NAMESPACE} -l ${STATEFULSET_SELECTOR} -o json | jq -r '.items[] | select(.status.conditions[]? | select(.type == "Ready" and .status == "False" and .reason != "PodCompleted")) | {kind: .kind, name: .metadata.name, conditions: .status.conditions}' | jq -s '. | length' | tr -d '\n'
        ...    env=${env}
        ...    secret_file__kubeconfig=${kubeconfig}

        ${unready_count}=    Convert To Integer    ${unreadypods_results.stdout}
        ${pods_notready_score}=    Evaluate    1 if ${unready_count} == 0 else 0

        Set Suite Variable    ${pod_readiness_details}    ${unready_count} unready pods
        Set Suite Variable    ${pods_notready_score}
        RW.Core.Push Metric    ${pods_notready_score}    sub_name=pod_readiness
    END

Get StatefulSet Replica Status and Score for `${STATEFULSET_NAME}`
    [Documentation]    Checks if the StatefulSet has the expected number of ready replicas and that all pods are on the latest revision.
    [Tags]    statefulset    replicas    revisions    status    availability    data:config

    # Skip if StatefulSet is scaled down
    IF    ${SKIP_HEALTH_CHECKS}
        Log    Skipping replica status check - StatefulSet is scaled to 0 replicas
        ${replica_score}=    Set Variable    1
        Set Suite Variable    ${replica_score}
        RW.Core.Push Metric    ${replica_score}    sub_name=replica_status
    ELSE
        ${statefulset_status}=    RW.CLI.Run Cli
        ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get statefulset/${STATEFULSET_NAME} --context ${CONTEXT} -n ${NAMESPACE} -o json | jq '.status | {ready_replicas: (.readyReplicas // 0), desired_replicas: (.replicas // 0), current_replicas: (.currentReplicas // 0), updated_replicas: (.updatedReplicas // 0), current_revision: (.currentRevision // ""), update_revision: (.updateRevision // "")}'
        ...    env=${env}
        ...    secret_file__kubeconfig=${kubeconfig}

        TRY
            ${status_json}=    Evaluate    json.loads(r'''${statefulset_status.stdout}''') if r'''${statefulset_status.stdout}'''.strip() else {}    json
            ${ready_replicas}=    Evaluate    $status_json.get('ready_replicas', 0)
            ${desired_replicas}=    Evaluate    $status_json.get('desired_replicas', 0)
            ${current_replicas}=    Evaluate    $status_json.get('current_replicas', 0)
            ${updated_replicas}=    Evaluate    $status_json.get('updated_replicas', 0)
            ${current_revision}=    Evaluate    $status_json.get('current_revision', '')
            ${update_revision}=    Evaluate    $status_json.get('update_revision', '')

            # Fully ready means: all desired replicas are ready, and any rolling update is complete.
            # A mid-rollout (updateRevision != currentRevision, or updated < desired) counts as degraded.
            ${all_ready}=    Evaluate    ${ready_replicas} >= ${desired_replicas} and ${desired_replicas} > 0
            ${rollout_complete}=    Evaluate    ("${current_revision}" == "${update_revision}" or "${update_revision}" == "") and ${updated_replicas} >= ${desired_replicas}

            IF    ${all_ready} and ${rollout_complete}
                ${replica_score}=    Set Variable    1
            ELSE IF    ${ready_replicas} >= 1 and ${rollout_complete}
                # Partially available and not mid-rollout: degraded, not fully failing
                ${replica_score}=    Set Variable    0.5
            ELSE
                ${replica_score}=    Set Variable    0
            END

            Set Suite Variable    ${replica_details}    ${ready_replicas}/${desired_replicas} ready, ${updated_replicas}/${desired_replicas} updated
        EXCEPT
            ${replica_score}=    Set Variable    0
            Set Suite Variable    ${replica_details}    status parse failed
        END

        Set Suite Variable    ${replica_score}
        RW.Core.Push Metric    ${replica_score}    sub_name=replica_status
    END

Get PersistentVolumeClaim Status and Score for StatefulSet `${STATEFULSET_NAME}`
    [Documentation]    Checks that PersistentVolumeClaims associated with the StatefulSet are Bound. Unbound PVCs commonly keep StatefulSet pods from starting.
    [Tags]    statefulset    pvc    storage    persistent    data:config

    # Skip if StatefulSet is scaled down
    IF    ${SKIP_HEALTH_CHECKS}
        Log    Skipping PVC check - StatefulSet is scaled to 0 replicas
        ${pvc_score}=    Set Variable    1
        Set Suite Variable    ${pvc_score}
        Set Suite Variable    ${pvc_details}    skipped (scaled to 0)
        RW.Core.Push Metric    ${pvc_score}    sub_name=pvc_status
    ELSE
        # Find PVCs owned by pods in this StatefulSet by matching pod selector. Falls back to name prefix
        # match for PVCs created by volumeClaimTemplates (which are named <template>-<statefulset>-<ordinal>).
        ${pvc_results}=    RW.CLI.Run Cli
        ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get pvc --context ${CONTEXT} -n ${NAMESPACE} -o json | jq '{total: ([.items[] | select(.metadata.name | test("-${STATEFULSET_NAME}-[0-9]+$"))] | length), unbound: ([.items[] | select((.metadata.name | test("-${STATEFULSET_NAME}-[0-9]+$")) and .status.phase != "Bound")] | length)}'
        ...    env=${env}
        ...    secret_file__kubeconfig=${kubeconfig}
        ...    timeout_seconds=30

        TRY
            ${pvc_json}=    Evaluate    json.loads(r'''${pvc_results.stdout}''') if r'''${pvc_results.stdout}'''.strip() else {}    json
            ${total_pvcs}=    Evaluate    $pvc_json.get('total', 0)
            ${unbound_pvcs}=    Evaluate    $pvc_json.get('unbound', 0)

            IF    ${total_pvcs} == 0
                # StatefulSet may not use volumeClaimTemplates - treat as healthy
                ${pvc_score}=    Set Variable    1
                Set Suite Variable    ${pvc_details}    no PVCs found
            ELSE IF    ${unbound_pvcs} == 0
                ${pvc_score}=    Set Variable    1
                ${bound_pvcs}=    Evaluate    ${total_pvcs} - ${unbound_pvcs}
                Set Suite Variable    ${pvc_details}    ${bound_pvcs}/${total_pvcs} bound
            ELSE
                ${pvc_score}=    Set Variable    0
                ${bound_pvcs}=    Evaluate    ${total_pvcs} - ${unbound_pvcs}
                Set Suite Variable    ${pvc_details}    ${bound_pvcs}/${total_pvcs} bound (${unbound_pvcs} unbound)
            END
        EXCEPT
            ${pvc_score}=    Set Variable    1
            Set Suite Variable    ${pvc_details}    pvc parse failed
        END

        Set Suite Variable    ${pvc_score}
        RW.Core.Push Metric    ${pvc_score}    sub_name=pvc_status
    END

Get Recent Warning Events Score for StatefulSet `${STATEFULSET_NAME}`
    [Documentation]    Checks for recent warning events related to the StatefulSet, its pods, and its PersistentVolumeClaims within a short time window.
    [Tags]    events    warnings    recent    fast    data:config

    # Even for scaled StatefulSets, we still check events since they may reveal scaling problems.
    # Pass the age in seconds via --argjson so jq receives a real number (avoids quoting issues and
    # lets us keep EVENT_AGE human-readable like "10m").
    ${event_age_seconds}=    Convert Duration To Seconds    ${EVENT_AGE}    default_seconds=600
    ${recent_events}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get events --context ${CONTEXT} -n ${NAMESPACE} -o json | jq --argjson age_seconds ${event_age_seconds} '(now - $age_seconds) as $time_limit | [ .items[] | select(.type == "Warning" and (.involvedObject.kind == "StatefulSet" or .involvedObject.kind == "Pod" or .involvedObject.kind == "PersistentVolumeClaim") and (.involvedObject.name | tostring | contains("${STATEFULSET_NAME}")) and (.lastTimestamp | fromdateiso8601) >= $time_limit and (.reason | test("FailedCreate|FailedScheduling|FailedMount|FailedAttachVolume|FailedPull|CrashLoopBackOff|ImagePullBackOff|ErrImagePull|Failed|Error|BackOff|ProvisioningFailed|VolumeFailedDelete"; "i"))) ] | length'
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}

    TRY
        ${event_count}=    Evaluate    int(r'''${recent_events.stdout}''') if r'''${recent_events.stdout}'''.strip() else 0
        ${threshold}=    Convert To Integer    ${EVENT_THRESHOLD}
        ${threshold_doubled}=    Evaluate    ${threshold} * 2

        # Threshold-based scoring: 1 if events <= threshold, 0.5 if <= threshold*2, else 0.
        ${events_score}=    Evaluate    1 if ${event_count} <= ${threshold} else (0.5 if ${event_count} <= ${threshold_doubled} else 0)

        Set Suite Variable    ${events_details}    ${event_count} events (threshold: ${threshold})
    EXCEPT
        ${events_score}=    Set Variable    1
        Set Suite Variable    ${events_details}    event parse failed
    END

    Set Suite Variable    ${events_score}
    RW.Core.Push Metric    ${events_score}    sub_name=warning_events


Generate StatefulSet Health Score for `${STATEFULSET_NAME}`
    @{unhealthy_components}=    Create List
    ${unhealthy_list}=    Set Variable    "None"

    IF    ${SKIP_HEALTH_CHECKS}
        # For scaled-down StatefulSets all sub-metrics are 1 (perfect) so the final score is also 1.
        # The scaled-down context is preserved in the report so intentional downtime is distinguishable from outages.
        ${health_score}=    Set Variable    1.0
        Log    StatefulSet ${STATEFULSET_NAME} is intentionally scaled to 0 replicas (${SCALED_DOWN_INFO}) - Score: ${health_score}
    ELSE
        ${active_checks}=    Set Variable    6
        ${statefulset_health_score}=    Evaluate    (${container_restart_score} + ${log_health_score} + ${pods_notready_score} + ${replica_score} + ${pvc_score} + ${events_score}) / ${active_checks}
        ${health_score}=    Convert to Number    ${statefulset_health_score}    2

        IF    ${container_restart_score} < 1    Append To List    ${unhealthy_components}    Container Restarts (${container_restart_details})
        IF    ${log_health_score} < 0.8    Append To List    ${unhealthy_components}    Log Health (${log_health_details})
        IF    ${pods_notready_score} < 1    Append To List    ${unhealthy_components}    Pod Readiness (${pod_readiness_details})
        IF    ${replica_score} < 1    Append To List    ${unhealthy_components}    Replica Status (${replica_details})
        IF    ${pvc_score} < 1    Append To List    ${unhealthy_components}    PVC Status (${pvc_details})
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
