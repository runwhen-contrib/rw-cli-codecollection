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
    ${BINARY_USED}=    RW.Core.Import User Variable    BINARY_USED
    ...    type=string
    ...    description=Which binary to use for Kubernetes CLI commands.
    ...    enum=[kubectl,oc]
    ...    example=kubectl
    ...    default=kubectl
    Set Suite Variable    ${kubeconfig}    ${kubeconfig}
    Set Suite Variable    ${kubectl}    ${kubectl}
    Set Suite Variable    ${CONTEXT}    ${CONTEXT}
    Set Suite Variable    ${BINARY_USED}    ${BINARY_USED}
    Set Suite Variable    ${NAMESPACE}    ${NAMESPACE}
    Set Suite Variable    ${ERROR_PATTERN}    ${ERROR_PATTERN}
    Set Suite Variable    ${env}    {"KUBECONFIG":"./${kubeconfig.key}"}

*** Tasks ***
Trace Namespace Errors
    [Documentation]    Queries all error events in a given namespace within the last 30 minutes,
    ...                fetches the list of involved pod names, requests logs from them and parses
    ...                the logs for exceptions.
    [Tags]    Namespace    Trace    Error    Pods    Events    Logs    Grep
    # get pods involved with error events
    ${error_events}=    RW.CLI.Run Cli
    ...    cmd=kubectl get events --field-selector type=Warning --context ${CONTEXT} -n ${NAMESPACE} -o json
    ...    target_service=${kubectl}
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
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
    ...    assign_stdout_from_var=involved_pod_names
    # get pods with restarts > 0
    ${pods_in_namespace}=    RW.CLI.Run Cli
    ...    cmd=kubectl get pods --context ${CONTEXT} -n ${NAMESPACE} -o json
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
    ...    assign_stdout_from_var=restart_pod_names
    # fetch logs with pod names
    ${restarting_pods}=    RW.CLI.From Json    json_str=${restarting_pods.stdout}
    ${involved_pod_names}=    RW.CLI.From Json    json_str=${involved_pod_names.stdout}
    ${podnames_to_query}=    Combine Lists    ${restarting_pods}    ${involved_pod_names}
    ${pod_logs_errors}=    RW.CLI.Run Cli
    ...    cmd=kubectl logs --context=${CONTEXT} --namespace=${NAMESPACE} pod/{item} --tail=100 | grep -E -i "${ERROR_PATTERN}"
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

Fetch Unready Pods
    [Documentation]    Fetches all pods which are not running (unready) in the namespace and raises an issue if any pods are found.
    [Tags]    Namespace    Pods    Status    Unready    Not Starting    Phase    Containers
    ${unreadypods_results}=    RW.CLI.Run Cli
    ...    cmd=kubectl get pods --context=${CONTEXT} -n ${NAMESPACE} --sort-by='status.containerStatuses[0].restartCount' --field-selector=status.phase!=Running
    ...    target_service=${kubectl}
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ${history}=    RW.CLI.Pop Shell History
    IF    """${unreadypods_results.stdout}""" == ""
        ${unreadypods_results}=    Set Variable    No unready pods found
    ELSE
        ${unreadypods_results}=    Set Variable    ${unreadypods_results.stdout}
    END
    RW.Core.Add Pre To Report    Summary of unready pod restarts in namespace: ${NAMESPACE}
    RW.Core.Add Pre To Report    ${unreadypods_results}
    RW.Core.Add Pre To Report    Commands Used:\n${history}


Check Workload Status Conditions
    [Documentation]    Parses all workloads in a namespace and inspects their status conditions for issues. Status conditions with a status value of False are considered an error.
    [Tags]    Namespace    Status    Conditions    Pods    Conditions    Reasons    Workloads
    ${all_resources}=    RW.CLI.Run Cli
    ...    cmd=kubectl get all --context ${CONTEXT} -n ${NAMESPACE} -o json
    ...    target_service=${kubectl}
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ${failing_conditions}=    RW.CLI.Parse Cli Json Output
    ...    rsp=${all_resources}
    ...    extract_path_to_var__workload_conditions=items[].{kind:kind, name:metadata.name, conditions:status.conditions[?status == `False`]}
    ...    from_var_with_path__workload_conditions__to__failing_workload_conditions=[?length(conditions || `[]`) > `0`]
    ...    from_var_with_path__failing_workload_conditions__to__aggregate_failures=[].{kind:kind,name:name,conditions:conditions[].{reason:reason, type:type, status:status}}
    ...    from_var_with_path__aggregate_failures__to__pods_with_failures=length(@)
    ...    pods_with_failures__raise_issue_if_gt=0
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


Namespace Get All
    [Documentation]    Simple fetch all to provide a snapshot of information about the workloads in the namespace.
    ${all_results}=    RW.CLI.Run Cli
    ...    cmd=kubectl get all --context=${CONTEXT} -n ${NAMESPACE}
    ...    target_service=${kubectl}
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Informational Get All for Namespace: ${NAMESPACE}
    RW.Core.Add Pre To Report    ${all_results}
    RW.Core.Add Pre To Report    Commands Used:\n${history}