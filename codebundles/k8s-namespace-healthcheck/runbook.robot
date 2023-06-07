*** Settings ***
Documentation       This taskset runs general troubleshooting checks against all applicable objects in a namespace, checks error events, and searches pod logs for error entries.
Metadata            Author    Jonathan Funk
Metadata            Display Name    Kubernetes Namespace Troubleshoot
Metadata            Supports    Kubernetes,AKS,EKS,GKE,OpenShift
Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             OperatingSystem
Library             DateTime
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
    ${kubectl}=    RW.Core.Import Service    kubectl
    ...    description=The location service used to interpret shell commands.
    ...    default=kubectl-service.shared
    ...    example=kubectl-service.shared
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
    ${ERROR_PATTERN}=    RW.Core.Import User Variable    ERROR_PATTERN
    ...    type=string
    ...    description=The error pattern to use when grep-ing logs.
    ...    pattern=\w*
    ...    example=(Error|Exception)
    ...    default=(Error|Exception)
    ${SERVICE_ERROR_PATTERN}=    RW.Core.Import User Variable    SERVICE_ERROR_PATTERN
    ...    type=string
    ...    description=The error pattern to use when grep-ing logs for services.
    ...    pattern=\w*
    ...    example=(Error: 13|Error: 14)
    ...    default=(Error:)
    ${SERVICE_EXCLUDE_PATTERN}=    RW.Core.Import User Variable    SERVICE_EXCLUDE_PATTERN
    ...    type=string
    ...    description=Pattern used to exclude entries from log results when searching in service logs.
    ...    pattern=\w*
    ...    example=(node_modules|opentelemetry)
    ...    default=(node_modules|opentelemetry)
    ${ANOMALY_THRESHOLD}=    RW.Core.Import User Variable    ANOMALY_THRESHOLD
    ...    type=string
    ...    description=At which count an event is considered an anomaly even when it's just informational according to Kubernetes.
    ...    pattern=\d+
    ...    example=100
    ...    default=100
    ${KUBERNETES_DISTRIBUTION_BINARY}=    RW.Core.Import User Variable    KUBERNETES_DISTRIBUTION_BINARY
    ...    type=string
    ...    description=Which binary to use for Kubernetes CLI commands.
    ...    enum=[kubectl,oc]
    ...    example=kubectl
    ...    default=kubectl
    Set Suite Variable    ${kubeconfig}    ${kubeconfig}
    Set Suite Variable    ${kubectl}    ${kubectl}
    Set Suite Variable    ${CONTEXT}    ${CONTEXT}
    Set Suite Variable    ${KUBERNETES_DISTRIBUTION_BINARY}    ${KUBERNETES_DISTRIBUTION_BINARY}
    Set Suite Variable    ${NAMESPACE}    ${NAMESPACE}
    Set Suite Variable    ${ERROR_PATTERN}    ${ERROR_PATTERN}
    Set Suite Variable    ${ANOMALY_THRESHOLD}    ${ANOMALY_THRESHOLD}
    Set Suite Variable    ${SERVICE_ERROR_PATTERN}    ${SERVICE_ERROR_PATTERN}
    Set Suite Variable    ${SERVICE_EXCLUDE_PATTERN}    ${SERVICE_EXCLUDE_PATTERN}
    Set Suite Variable    ${env}    {"KUBECONFIG":"./${kubeconfig.key}"}

*** Tasks ***
Trace And Troubleshoot Namespace Warning Events And Errors
    [Documentation]    Queries all error events in a given namespace within the last 30 minutes,
    ...                fetches the list of involved pod names, requests logs from them and parses
    ...                the logs for exceptions.
    [Tags]    Namespace    Trace    Error    Pods    Events    Logs    Grep
    # get pods involved with error events
    ${error_events}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get events --field-selector type=Warning --context ${CONTEXT} -n ${NAMESPACE} -o json
    ...    target_service=${kubectl}
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    render_in_commandlist=true
    ${recent_error_events}=    RW.CLI.Parse Cli Json Output
    ...    rsp=${error_events}
    ...    extract_path_to_var__recent_events=items
    ...    recent_events__filter_older_than__60m=lastTimestamp
    ...    assign_stdout_from_var=recent_events
    ${involved_pod_names}=    RW.CLI.Parse Cli Json Output
    ...    rsp=${error_events}
    ...    extract_path_to_var__involved_pod_names=items[?involvedObject.kind=='Pod'].involvedObject.name
    ...    from_var_with_path__involved_pod_names__to__pod_count=length(@)
    ...    pod_count__raise_issue_if_gt=0
    ...    set_issue_title=Pods Found With Recent Warning Events In Namespace ${NAMESPACE}
    ...    set_issue_details=We found $pod_count pods with events of type Warning in the namespace ${NAMESPACE}.\nName of pods with issues:\n$involved_pod_names\nCheck pod or namespace events.
    ...    assign_stdout_from_var=involved_pod_names
    # get pods with restarts > 0
    ${pods_in_namespace}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get pods --context ${CONTEXT} -n ${NAMESPACE} -o json
    ...    target_service=${kubectl}
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ${restart_age}=    RW.CLI.String To Datetime    30m
    ${restarting_pods}=    RW.CLI.Parse Cli Json Output
    ...    rsp=${pods_in_namespace}
    ...    extract_path_to_var__pod_restart_stats=items[].{name:metadata.name, containerRestarts:status.containerStatuses[].{restartCount:restartCount, terminated_at:lastState.terminated.finishedAt}|[?restartCount > `0` && terminated_at >= `${restart_age}`]}
    ...    from_var_with_path__pod_restart_stats__to__pods_with_recent_restarts=[].{name: name, restartSum:sum(containerRestarts[].restartCount || [`0`])}|[?restartSum > `0`]
    ...    from_var_with_path__pods_with_recent_restarts__to__restart_pod_names=[].name
    ...    from_var_with_path__pods_with_recent_restarts__to__pod_count=length(@)
    ...    pod_count__raise_issue_if_gt=0
    ...    set_issue_title=Frequently Restarting Pods In Namespace ${NAMESPACE}
    ...    set_issue_details=Found $pod_count pods that are frequently restarting in ${NAMESPACE}. Check pod logs, status, namespace events, or pod resource configuration. 
    ...    assign_stdout_from_var=restart_pod_names
    # fetch logs with pod names
    ${restarting_pods}=    RW.CLI.From Json    json_str=${restarting_pods.stdout}
    ${involved_pod_names}=    RW.CLI.From Json    json_str=${involved_pod_names.stdout}
    ${podnames_to_query}=    Combine Lists    ${restarting_pods}    ${involved_pod_names}
    ${pod_logs_errors}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} logs --context=${CONTEXT} --namespace=${NAMESPACE} pod/{item} --tail=100 | grep -E -i "${ERROR_PATTERN}" || true
    ...    target_service=${kubectl}
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    loop_with_items=${podnames_to_query}
    ${history}=    RW.CLI.Pop Shell History
    IF    """${pod_logs_errors}""" != ""
        ${error_trace_results}=    Set Variable    Found error logs:\nEffected Pods: ${podnames_to_query}\n${pod_logs_errors}\n
    ELSE
        ${error_trace_results}=    Set Variable    No trace errors found!
    END
    RW.Core.Add Pre To Report    Summary of error trace in namespace: ${NAMESPACE}
    RW.Core.Add Pre To Report    ${error_trace_results}
    RW.Core.Add Pre To Report    Commands Used:\n${history}

Troubleshoot Unready Pods In Namespace For Report
    [Documentation]    Fetches all pods which are not running (unready) in the namespace and adds them to a report for future review.
    [Tags]    Namespace    Pods    Status    Unready    Not Starting    Phase    Containers
    ${unreadypods_results}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get pods --context=${CONTEXT} -n ${NAMESPACE} --sort-by='status.containerStatuses[0].restartCount' --field-selector=status.phase!=Running -o=name
    ...    target_service=${kubectl}
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    render_in_commandlist=true
    RW.CLI.Parse Cli Output By Line
    ...    rsp=${unreadypods_results}
    ...    set_severity_level=3
    ...    set_issue_expected=No pods should be in an unready state
    ...    set_issue_actual=We found the following unready pods: $_stdout
    ...    set_issue_title=Unready Pods Detected In Namespace ${NAMESPACE}
    ...    set_issue_details=We found the following unready pods: $_stdout in the namespace ${NAMESPACE}
    ...    _line__raise_issue_if_contains=pod
    ${history}=    RW.CLI.Pop Shell History
    IF    """${unreadypods_results.stdout}""" == ""
        ${unreadypods_results}=    Set Variable    No unready pods found
    ELSE
        ${unreadypods_results}=    Set Variable    ${unreadypods_results.stdout}
    END
    RW.Core.Add Pre To Report    Summary of unready pod restarts in namespace: ${NAMESPACE}
    RW.Core.Add Pre To Report    ${unreadypods_results}
    RW.Core.Add Pre To Report    Commands Used:\n${history}


Troubleshoot Workload Status Conditions In Namespace
    [Documentation]    Parses all workloads in a namespace and inspects their status conditions for issues. Status conditions with a status value of False are considered an error.
    [Tags]    Namespace    Status    Conditions    Pods    Conditions    Reasons    Workloads
    ${all_resources}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get all --context ${CONTEXT} -n ${NAMESPACE} -o json
    ...    target_service=${kubectl}
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    render_in_commandlist=true
    ${failing_conditions}=    RW.CLI.Parse Cli Json Output
    ...    rsp=${all_resources}
    ...    extract_path_to_var__workload_conditions=items[].{kind:kind, name:metadata.name, conditions:status.conditions[?status == `False`]}
    ...    from_var_with_path__workload_conditions__to__failing_workload_conditions=[?length(conditions || `[]`) > `0`]
    ...    from_var_with_path__failing_workload_conditions__to__aggregate_failures=[].{kind:kind,name:name,conditions:conditions[].{reason:reason, type:type, status:status}}
    ...    from_var_with_path__aggregate_failures__to__pods_with_failures=length(@)
    ...    pods_with_failures__raise_issue_if_gt=0
    ...    set_issue_title=Pods With Unhealthy Status In Namespace ${NAMESPACE}
    ...    set_issue_details=Found $pods_with_failures pods with an unhealthy status condition in the namespace ${NAMESPACE}. Review status conditions, pod logs, pod events, or namespace events. 
    ...    assign_stdout_from_var=aggregate_failures
    ${history}=    RW.CLI.Pop Shell History
    IF    """${failing_conditions.stdout}""" == ""
        ${failing_conditions}=    Set Variable    No unready pods found
    ELSE
        ${failing_conditions}=    Set Variable    ${failing_conditions.stdout}
    END
    RW.Core.Add Pre To Report    Summary of Pods with Failing Conditions in Namespace: ${NAMESPACE}
    RW.Core.Add Pre To Report    ${failing_conditions}
    RW.Core.Add Pre To Report    Commands Used:\n${history}


Get Listing Of Workloads In Namespace
    [Documentation]    Simple fetch all to provide a snapshot of information about the workloads in the namespace for future review in a report.
    [Tags]    Get All    Resources    Info    Workloads    Namespace    Manifests
    ${all_results}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get all --context=${CONTEXT} -n ${NAMESPACE}
    ...    target_service=${kubectl}
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    render_in_commandlist=true
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Informational Get All for Namespace: ${NAMESPACE}
    RW.Core.Add Pre To Report    ${all_results}
    RW.Core.Add Pre To Report    Commands Used:\n${history}

Check For Namespace Event Anomalies
    [Documentation]    Parses all events in a namespace within a timeframe and checks for unusual activity, raising issues for any found.
    [Tags]    Namespace    Events    Info    State    Anomolies    Count    Occurences
    ${recent_anomalies}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get events --field-selector type!=Warning --context ${CONTEXT} -n ${NAMESPACE} -o json | jq -r '.items[] | select((now - (.lastTimestamp | fromdate)) < 1800) | select(.count > ${ANOMALY_THRESHOLD}) | "Count:" + (.count|tostring) + " Object:" + .involvedObject.namespace + "/" + .involvedObject.kind + "/" + .involvedObject.name + " Reason:" + .reason + " Message:" + .message'
    ...    target_service=${kubectl}
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    RW.CLI.Parse Cli Output By Line
    ...    rsp=${recent_anomalies}
    ...    set_severity_level=3
    ...    set_issue_expected=No unusual recent anomaly events with high counts in the namespace ${NAMESPACE}
    ...    set_issue_actual=We detected events in the namespace ${NAMESPACE} which are considered anomalies
    ...    set_issue_title=Event Anomalies Detected In Namespace ${NAMESPACE}
    ...    set_issue_details=Here's a summary of the anomaly events which may indicate an underlying issue that's not surfacing errors:\n$_stdout
    ...    _line__raise_issue_if_contains=Object
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add To Report    Summary Of Anomalies Detected:\n
    RW.Core.Add To Report   ${recent_anomalies.stdout}\n
    RW.Core.Add Pre To Report    Commands Used:\n${history}


Troubleshoot Namespace Services And Application Workloads
    [Documentation]    Iterates through the services within a namespace for a given timeframe and byte length max, checking the resulting logs for distinct entries matching a given pattern in order to determine a root issue.
    [Tags]    Namespace    Services    Applications    Workloads    Deployments    Apps    Ingress    HTTP    Networking    Endpoints    Logs    Aggregate    Filter
    ${aggregate_service_logs}=    RW.CLI.Run Cli
    ...    cmd=services=($(${KUBERNETES_DISTRIBUTION_BINARY} get svc -o=name --context=${CONTEXT} -n ${NAMESPACE})); logs=""; for service in "\${services[@]}"; do logs+=$(${KUBERNETES_DISTRIBUTION_BINARY} logs $service --limit-bytes=256000 --since=2h --context=${CONTEXT} -n ${NAMESPACE} | grep -Ei "${SERVICE_ERROR_PATTERN}" | grep -Ev "${SERVICE_EXCLUDE_PATTERN}" | sort | uniq -c | awk '{print "Issue Occurences:",$0}'); done; echo "\${logs}"
    ...    target_service=${kubectl}
    ...    env=${env}
    ...    secret_file__kubeconfig=${KUBECONFIG}
    ...    render_in_commandlist=true
    RW.CLI.Parse Cli Output By Line
    ...    rsp=${aggregate_service_logs}
    ...    set_severity_level=2
    ...    set_issue_expected=Service workload logs in namespace ${NAMESPACE} should not contain any error entries
    ...    set_issue_actual=Service workload logs in namespace ${NAMESPACE} contain errors entries
    ...    set_issue_title=Service Workloads In Namespace ${NAMESPACE} Have Error Log Entries
    ...    set_issue_details=We found the following distinctly counted errors in the service workloads of namespace ${NAMESPACE}:\n\n$_stdout\n\nThese errors may be related to other workloads that need triaging
    ...    _line__raise_issue_if_contains=Error
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add To Report    Sample Of Aggregate Counted Logs Found:\n
    RW.Core.Add To Report   ${aggregate_service_logs.stdout}\n
    RW.Core.Add Pre To Report    Commands Used:\n${history}

