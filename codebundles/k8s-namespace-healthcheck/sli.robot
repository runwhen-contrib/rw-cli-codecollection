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
    ${EVENT_AGE}=    RW.Core.Import User Variable    EVENT_AGE
    ...    type=string
    ...    description=The time window in minutes as to when the event was last seen.
    ...    pattern=((\d+?)m)?
    ...    example=5m
    ...    default=5m
    ${EVENT_THRESHOLD}=    RW.Core.Import User Variable    EVENT_THRESHOLD
    ...    type=string
    ...    description=The maximum total events to be still considered healthy. 
    ...    pattern=^\d+$
    ...    example=2
    ...    default=2
    ${CONTAINER_RESTART_AGE}=    RW.Core.Import User Variable    CONTAINER_RESTART_AGE
    ...    type=string
    ...    description=The time window in minutes as search for container restarts.
    ...    pattern=((\d+?)m)?
    ...    example=5m
    ...    default=5m
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
    Set Suite Variable    ${kubeconfig}    ${kubeconfig}
    Set Suite Variable    ${KUBERNETES_DISTRIBUTION_BINARY}    ${KUBERNETES_DISTRIBUTION_BINARY}
    Set Suite Variable    ${EVENT_AGE}    ${EVENT_AGE}
    Set Suite Variable    ${EVENT_THRESHOLD}    ${EVENT_THRESHOLD}
    Set Suite Variable    ${CONTAINER_RESTART_AGE}    ${CONTAINER_RESTART_AGE}
    Set Suite Variable    ${CONTAINER_RESTART_THRESHOLD}    ${CONTAINER_RESTART_THRESHOLD}
    Set Suite Variable    ${CONTEXT}    ${CONTEXT}
    Set Suite Variable    ${NAMESPACE}    ${NAMESPACE}
    Set Suite Variable    ${env}    {"KUBECONFIG":"./${kubeconfig.key}"}

*** Tasks ***
Get Event Count and Score
    [Documentation]    Captures error events and counts them within a configurable timeframe.
    [Tags]    Event    Count    Warning
    ${error_events}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get events --field-selector type=Warning --context ${CONTEXT} -n ${NAMESPACE} -o json
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ${EVENT_AGE}=    RW.CLI.String To Datetime    ${EVENT_AGE}
    ${error_event_count}=    RW.CLI.Parse Cli Json Output
    ...    rsp=${error_events}
    ...    extract_path_to_var__recent_error_events=items[].{name:metadata.name, eventlts:lastTimestamp, message:message}|[?eventlts >= `${EVENT_AGE}`]
    ...    from_var_with_path__recent_error_events__to__event_count=length(@)
    ...    assign_stdout_from_var=event_count
    Log    ${error_event_count.stdout} total events found with event type Warning up to age ${EVENT_AGE}
    ${event_score}=    Evaluate    1 if ${error_event_count.stdout} <= ${EVENT_THRESHOLD} else 0
    Set Global Variable    ${event_score}

Get Container Restarts and Score
    [Documentation]    Counts the total sum of container restarts within a timeframe and determines if they're beyond a threshold.
    [Tags]    Restarts    Pods    Containers    Count    Status
    ${pods}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get pods --context ${CONTEXT} -n ${NAMESPACE} -o json
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
    Set Global Variable    ${container_restart_score}

Get NotReady Pods
    [Documentation]    Fetches a count of unready pods.
    [Tags]    Pods    Status    Phase    Ready    Unready    Running
    ${unreadypods_results}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get pods --context ${CONTEXT} -n ${NAMESPACE} -o json | jq -r '.items[] | select(.status.conditions[]? | select(.type == "Ready" and .status == "False" and .reason != "PodCompleted")) | {kind: .kind, name: .metadata.name, conditions: .status.conditions}' | jq -s '. | length'
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    Log    ${unreadypods_results.stdout} total unready pods
    ${pods_notready_score}=    Evaluate    1 if ${unreadypods_results.stdout} == 0 else 0
    Set Global Variable    ${pods_notready_score}

Generate Namspace Score
    ${namespace_health_score}=      Evaluate  (${event_score} + ${container_restart_score} + ${pods_notready_score}) / 3
    ${health_score}=      Convert to Number    ${namespace_health_score}  2
    RW.Core.Push Metric    ${health_score}