*** Settings ***
Metadata          Author    stewartshea
Documentation     This SLI uses kubectl to score namespace health. Produces a value between 0 (completely failing thet test) and 1 (fully passing the test). Looks for container restarts, events, and pods not ready.
Metadata          Display Name    Kubernetes Namespace Healthcheck
Metadata          Supports    Kubernetes,AKS,EKS,GKE,OpenShift
Suite Setup       Suite Initialization
Library           BuiltIn
Library           RW.Core
Library           RW.CLI
Library           RW.platform
Library           OperatingSystem
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
    ...    description=The name of the Kubernetes namespace to scope actions and searching to. Supports csv list of namespaces. 
    ...    pattern=\w*
    ...    example=my-namespace
    ${CONTEXT}=    RW.Core.Import User Variable    CONTEXT
    ...    type=string
    ...    description=Which Kubernetes context to operate within.
    ...    pattern=\w*
    ...    example=my-main-cluster
    ${EVENT_THRESHOLD}=    RW.Core.Import User Variable    EVENT_THRESHOLD
    ...    type=string
    ...    description=The maximum total events to be still considered healthy. 
    ...    pattern=^\d+$
    ...    example=4
    ...    default=4
    ${CONTAINER_RESTART_THRESHOLD}=    RW.Core.Import User Variable    CONTAINER_RESTART_THRESHOLD
    ...    type=string
    ...    description=The maximum total container restarts to be still considered healthy. 
    ...    pattern=^\d+$
    ...    example=2
    ...    default=3
    ${KUBERNETES_DISTRIBUTION_BINARY}=    RW.Core.Import User Variable    KUBERNETES_DISTRIBUTION_BINARY
    ...    type=string
    ...    description=Which binary to use for Kubernetes CLI commands.
    ...    enum=[kubectl,oc]
    ...    example=kubectl
    ...    default=kubectl
    ${RW_LOOKBACK_WINDOW}=    RW.Core.Import Platform Variable    RW_LOOKBACK_WINDOW
    ${RW_LOOKBACK_WINDOW}=    RW.Core.Normalize Lookback Window     ${RW_LOOKBACK_WINDOW}     2
    Set Suite Variable    ${kubeconfig}    ${kubeconfig}
    Set Suite Variable    ${KUBERNETES_DISTRIBUTION_BINARY}    ${KUBERNETES_DISTRIBUTION_BINARY}
    Set Suite Variable    ${EVENT_THRESHOLD}    ${EVENT_THRESHOLD}
    Set Suite Variable    ${CONTAINER_RESTART_THRESHOLD}    ${CONTAINER_RESTART_THRESHOLD}
    Set Suite Variable    ${CONTEXT}    ${CONTEXT}
    Set Suite Variable    ${NAMESPACE}    ${NAMESPACE}
    Set Suite Variable    ${RW_LOOKBACK_WINDOW}    ${RW_LOOKBACK_WINDOW}
    Set Suite Variable    ${env}    {"KUBECONFIG":"./${kubeconfig.key}", "RW_LOOKBACK_WINDOW": "${RW_LOOKBACK_WINDOW}"}


*** Tasks ***
Get Error Event Count within ${RW_LOOKBACK_WINDOW} and calculate Score
    [Documentation]    Captures error events and counts them within the RW_LOOKBACK_WINDOW timeframe, consistent with runbook analysis.
    [Tags]     Event    Count    Warning    data:config
    ${error_events}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get events --field-selector type=Warning --context ${CONTEXT} -n ${NAMESPACE} -o json
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ${RW_LOOKBACK_WINDOW_DATETIME}=    RW.CLI.String To Datetime    ${RW_LOOKBACK_WINDOW}
    ${error_event_count}=    RW.CLI.Parse Cli Json Output
    ...    rsp=${error_events}
    ...    extract_path_to_var__recent_error_events=items[].{name:metadata.name, eventlts:lastTimestamp, message:message}|[?eventlts >= `${RW_LOOKBACK_WINDOW_DATETIME}`]
    ...    from_var_with_path__recent_error_events__to__event_count=length(@)
    ...    assign_stdout_from_var=event_count
    Log    ${error_event_count.stdout} total events found with event type Warning up to age ${RW_LOOKBACK_WINDOW}
    
    ${event_count}=    Convert To Integer    ${error_event_count.stdout}
    ${threshold}=    Convert To Integer    ${EVENT_THRESHOLD}
    ${event_score}=    Evaluate    1 if ${event_count} <= ${threshold} else 0
    
    # Store details for final score calculation logging
    Set Suite Variable    ${event_details}    ${event_count} events (threshold: ${threshold})
    Set Suite Variable    ${event_score}
    RW.Core.Push Metric    ${event_score}    sub_name=error_events

Get Container Restarts and Score in Namespace `${NAMESPACE}`
    [Documentation]    Counts the total sum of container restarts within a timeframe and determines if they're beyond a threshold.
    [Tags]    Restarts    Pods    Containers    Count    Status    data:config
    ${pods}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get pods --context ${CONTEXT} -n ${NAMESPACE} -o json
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    timeout_seconds=300
    ${RW_LOOKBACK_WINDOW_DATETIME}=    RW.CLI.String To Datetime    ${RW_LOOKBACK_WINDOW}
    ${container_restarts_sum}=    RW.CLI.Parse Cli Json Output
    ...    rsp=${pods}
    ...    extract_path_to_var__pod_restart_stats=items[].{name:metadata.name, containerRestarts:status.containerStatuses[].{restartCount:restartCount, terminated_at:lastState.terminated.finishedAt}|[?restartCount > `0` && terminated_at >= `${RW_LOOKBACK_WINDOW_DATETIME}`]}
    ...    from_var_with_path__pod_restart_stats__to__pods_with_recent_restarts=[].{name: name, restartSum:sum(containerRestarts[].restartCount || [`0`])}|[?restartSum > `0`]
    ...    from_var_with_path__pods_with_recent_restarts__to__restart_sum=sum([].restartSum)
    ...    assign_stdout_from_var=restart_sum
    Log    ${container_restarts_sum.stdout} total container restarts found in the last ${RW_LOOKBACK_WINDOW}
    
    ${restart_count}=    Convert To Integer    ${container_restarts_sum.stdout}
    ${threshold}=    Convert To Integer    ${CONTAINER_RESTART_THRESHOLD}
    ${container_restart_score}=    Evaluate    1 if ${restart_count} <= ${threshold} else 0
    
    # Store details for final score calculation logging
    Set Suite Variable    ${container_restart_details}    ${restart_count} restarts (threshold: ${threshold})
    Set Suite Variable    ${container_restart_score}
    RW.Core.Push Metric    ${container_restart_score}    sub_name=container_restarts

Get NotReady Pods in `${NAMESPACE}`
    [Documentation]    Fetches a count of unready pods.
    [Tags]     access:read-only  Pods    Status    Phase    Ready    Unready    Running    data:config
    ${unreadypods_results}=    RW.CLI.Run Cli
    ...    cmd=TIME_PERIOD="${RW_LOOKBACK_WINDOW}"; if [[ \$TIME_PERIOD =~ ^([0-9]+)h\$ ]]; then SECONDS_AGO=\$((\$\{BASH_REMATCH[1]\} * 3600)); elif [[ \$TIME_PERIOD =~ ^([0-9]+)m\$ ]]; then SECONDS_AGO=\$((\$\{BASH_REMATCH[1]\} * 60)); else SECONDS_AGO=3600; fi; THRESHOLD_TIME=\$(date -u -d "@\$((\$(date +%s) - \$SECONDS_AGO))" +"%Y-%m-%dT%H:%M:%SZ"); ${KUBERNETES_DISTRIBUTION_BINARY} get pods --context ${CONTEXT} -n ${NAMESPACE} -o json | jq -r --arg threshold_time "\$THRESHOLD_TIME" '.items[] | select(.status.conditions[]? | select(.type == "Ready" and .status == "False" and .reason != "PodCompleted")) | select((.status.conditions[] | select(.type == "Ready") | .lastTransitionTime // "1970-01-01T00:00:00Z") > \$threshold_time) | {kind: .kind, name: .metadata.name, conditions: .status.conditions}' | jq -s '. | length' | tr -d '\n'
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    Log    ${unreadypods_results.stdout} total unready pods
    
    ${unready_count}=    Convert To Integer    ${unreadypods_results.stdout}
    ${pods_notready_score}=    Evaluate    1 if ${unready_count} == 0 else 0
    
    # Store details for final score calculation logging
    Set Suite Variable    ${pod_readiness_details}    ${unready_count} unready pods
    Set Suite Variable    ${pods_notready_score}
    RW.Core.Push Metric    ${pods_notready_score}    sub_name=pod_readiness

Generate Namespace Score in `${NAMESPACE}`
    @{unhealthy_components}=    Create List
    ${namespace_health_score}=      Evaluate  (${event_score} + ${container_restart_score} + ${pods_notready_score}) / 3
    ${health_score}=      Convert to Number    ${namespace_health_score}  2
    
    # Create detailed breakdown of unhealthy components using stored suite variables
    IF    ${event_score} < 1    Append To List    ${unhealthy_components}    Warning Events (${event_details})
    IF    ${container_restart_score} < 1    Append To List    ${unhealthy_components}    Container Restarts (${container_restart_details})
    IF    ${pods_notready_score} < 1    Append To List    ${unhealthy_components}    Pod Readiness (${pod_readiness_details})
    
    ${unhealthy_count}=    Get Length    ${unhealthy_components}
    IF    ${unhealthy_count} > 0
        ${unhealthy_list}=    Evaluate    ', '.join(@{unhealthy_components})
    ELSE
        ${unhealthy_list}=    Set Variable    None
        Log    Health Score: ${health_score} - All components healthy
    END
    
    RW.Core.Add to Report    Health Score: ${health_score} - Unhealthy components: ${unhealthy_list}
    RW.Core.Push Metric    ${health_score}