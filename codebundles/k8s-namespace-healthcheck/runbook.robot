*** Settings ***
Documentation       This taskset runs general troubleshooting checks against all applicable objects in a namespace, checks error events, and searches pod logs for error entries.
Metadata            Author    jon-funk
Metadata            Display Name    Kubernetes Namespace Troubleshoot
Metadata            Supports    Kubernetes,AKS,EKS,GKE,OpenShift

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.NextSteps
Library             RW.platform
Library             OperatingSystem
Library             DateTime
Library             Collections

Suite Setup         Suite Initialization


*** Tasks ***
Trace And Troubleshoot Namespace Warning Events And Errors
    [Documentation]    Queries all error events in a given namespace within the last 30 minutes,
    ...    fetches the list of involved pod names, requests logs from them and parses
    ...    the logs for exceptions.
    [Tags]    namespace    trace    error    pods    events    logs    grep
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

    ${involved_pod_names}=    RW.CLI.Run Cli
    ...    cmd=cat << 'EOF' | jq -r '.items[] | select(.involvedObject.kind == "Pod") | .involvedObject.name' | tr -d "\n"\n${error_events.stdout}EOF
    ...    include_in_history=False
    ${involved_pod_names_array}=    Evaluate    """${involved_pod_names.stdout}""".split("\\n")
    ${event_messages}=    RW.CLI.Run Cli
    ...    cmd=cat << 'EOF' | jq -r '.items[] | select(.involvedObject.kind == "Pod") | .message' | tr -d "\n"\n${error_events.stdout}EOF
    ...    include_in_history=False
    ${event_messages_array}=    Evaluate    """${event_messages.stdout}""".split("\\n")
    ${next_steps}=    RW.NextSteps.Suggest
    ...    Pods in namespace ${NAMESPACE} have associated warning events ${event_messages_array}
    ${next_steps}=    RW.NextSteps.Format    ${next_steps}
    ...    pod_names=${involved_pod_names_array}

    ${involved_pod_names}=    RW.CLI.Parse Cli Json Output
    ...    rsp=${error_events}
    ...    extract_path_to_var__involved_pod_names=items[?involvedObject.kind=='Pod'].involvedObject.name
    ...    from_var_with_path__involved_pod_names__to__pod_count=length(@)
    ...    pod_count__raise_issue_if_gt=0
    ...    set_issue_title=$pod_count Pods Found With Recent Warning Events In Namespace ${NAMESPACE}
    ...    set_issue_details=Warning events in the namespace ${NAMESPACE}.\nName of pods with issues:\n"$involved_pod_names"\nTroubleshoot pod or namespace events:\n"${recent_error_events.stdout}"
    ...    set_issue_next_steps=${next_steps}
    ...    assign_stdout_from_var=involved_pod_names
    # get pods with restarts > 0
    ${pods_in_namespace}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get pods --context ${CONTEXT} -n ${NAMESPACE} -o json
    ...    target_service=${kubectl}
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ${restart_age}=    RW.CLI.String To Datetime    30m
    ${pod_names}=    RW.CLI.Run Cli
    ...    cmd=cat << 'EOF' | jq -r '.items[].metadata.name'\n${error_events.stdout}EOF
    ...    include_in_history=False
    ${next_steps}=    RW.NextSteps.Suggest    Pods in namespace ${NAMESPACE} are restarting: ${pod_names.stdout}
    ${next_steps}=    RW.NextSteps.Format    ${next_steps}
    ...    pod_name=${pod_names.stdout}
    ${restarting_pods}=    RW.CLI.Parse Cli Json Output
    ...    rsp=${pods_in_namespace}
    ...    extract_path_to_var__pod_restart_stats=items[].{name:metadata.name, containerRestarts:status.containerStatuses[].{restartCount:restartCount, terminated_at:lastState.terminated.finishedAt}|[?restartCount > `0` && terminated_at >= `${restart_age}`]}
    ...    from_var_with_path__pod_restart_stats__to__pods_with_recent_restarts=[].{name: name, restartSum:sum(containerRestarts[].restartCount || [`0`])}|[?restartSum > `0`]
    ...    from_var_with_path__pods_with_recent_restarts__to__restart_pod_names=[].name
    ...    from_var_with_path__pods_with_recent_restarts__to__pod_count=length(@)
    ...    pod_count__raise_issue_if_gt=0
    ...    set_issue_title=Frequently Restarting Pods In Namespace ${NAMESPACE}
    ...    set_issue_details=Found $pod_count pods that are frequently restarting in ${NAMESPACE}. Troubleshoot these pods:\n"$pods_with_recent_restarts"
    ...    set_issue_next_steps=${next_steps}
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
    IF    """${pod_logs_errors.stdout}""" != ""
        ${error_trace_results}=    Set Variable
        ...    Found error logs:\n${pod_logs_errors.stdout}\n\nEffected Pods: ${podnames_to_query}\n
    ELSE
        ${error_trace_results}=    Set Variable    No trace errors found!
    END
    RW.Core.Add Pre To Report    Summary of error trace in namespace: ${NAMESPACE}
    RW.Core.Add Pre To Report    ${error_trace_results}
    RW.Core.Add Pre To Report    Commands Used:\n${history}

Troubleshoot Container Restarts In Namespace
    [Documentation]    Fetches pods that have container restarts and provides a report of the restart issues.
    [Tags]    namespace    containers    status    restarts
    ${container_restart_details}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get pods --context=${CONTEXT} -n ${NAMESPACE} -o json | jq -r --argjson exit_code_explanations '{"0": "Success", "1": "Error", "2": "Misconfiguration", "130": "Pod terminated by SIGINT", "134": "Abnormal Termination SIGABRT", "137": "Pod terminated by SIGKILL - Possible OOM", "143":"Graceful Termination SIGTERM"}' '.items[] | select(.status.containerStatuses != null) | select(any(.status.containerStatuses[]; .restartCount > 0)) | "---\\npod_name: \\(.metadata.name)\\n" + (.status.containerStatuses[] | "containers: \\(.name)\\nrestart_count: \\(.restartCount)\\nmessage: \\(.state.waiting.message // "N/A")\\nterminated_reason: \\(.lastState.terminated.reason // "N/A")\\nterminated_finishedAt: \\(.lastState.terminated.finishedAt // "N/A")\\nterminated_exitCode: \\(.lastState.terminated.exitCode // "N/A")\\nexit_code_explanation: \\($exit_code_explanations[.lastState.terminated.exitCode | tostring] // "Unknown exit code")") + "\\n---\\n"'
    ...    target_service=${kubectl}
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    render_in_commandlist=true
    ${pod_name}=    RW.CLI.Run Cli
    ...    cmd=echo "${container_restart_details.stdout}" | awk -F': ' '/pod_name:/ {print $2}'
    ...    include_in_history=false
    ${message_details}=    RW.CLI.Run Cli
    ...    cmd=echo "${container_restart_details.stdout}" | awk -F': ' '/message:/ {print $2}'
    ...    include_in_history=false
    ${next_steps}=    RW.NextSteps.Suggest    ${message_details.stdout}
    ${next_steps}=    RW.NextSteps.Format    ${next_steps}
    ...    pod_name=${pod_name.stdout}
    ...    workload_name=${pod_name.stdout}
    RW.CLI.Parse Cli Output By Line
    ...    rsp=${container_restart_details}
    ...    set_severity_level=2
    ...    set_issue_expected=Containers should not be restarting.
    ...    set_issue_actual=We found the following containers with restarts: $_stdout
    ...    set_issue_title=Container Restarts Detected In Namespace ${NAMESPACE}
    ...    set_issue_details=Pods with Container Restarts:\n"$_stdout" in the namespace ${NAMESPACE}
    ...    set_issue_next_steps=${next_steps}
    ...    _line__raise_issue_if_contains=restart_count
    ${history}=    RW.CLI.Pop Shell History
    IF    """${container_restart_details.stdout}""" == ""
        ${container_restart_details}=    Set Variable    No container restarts found
    ELSE
        ${container_restart_details}=    Set Variable    ${container_restart_details.stdout}
    END
    RW.Core.Add Pre To Report    Summary of unready container restarts in namespace: ${NAMESPACE}
    RW.Core.Add Pre To Report    ${container_restart_details}
    RW.Core.Add Pre To Report    Commands Used:\n${history}

Troubleshoot Pending Pods In Namespace
    [Documentation]    Fetches pods that are pending and provides details.
    [Tags]    namespace    pods    status    pending
    ${pending_pods}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get pods --context=${CONTEXT} -n ${NAMESPACE} --field-selector=status.phase=Pending --no-headers -o json | jq -r '.items[] | "---\\npod_name: \\(.metadata.name)\\nstatus: \\(.status.phase // "N/A")\\nmessage: \\(.status.conditions[].message // "N/A")\\nreason: \\(.status.conditions[].reason // "N/A")\\ncontainerStatus: \\((.status.containerStatuses // [{}])[].state // "N/A")\\ncontainerMessage: \\((.status.containerStatuses // [{}])[].state?.waiting?.message // "N/A")\\ncontainerReason: \\((.status.containerStatuses // [{}])[].state?.waiting?.reason // "N/A")\\n---\\n"'
    ...    target_service=${kubectl}
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    render_in_commandlist=true
    ${next_steps}=    RW.NextSteps.Suggest    ${pending_pods.stdout}
    RW.CLI.Parse Cli Output By Line
    ...    rsp=${pending_pods}
    ...    set_severity_level=1
    ...    set_issue_expected=Pods should not be stuck pending.
    ...    set_issue_actual=We found the following pods in a pending state: $_stdout
    ...    set_issue_title=Pending Pods Found In Namespace ${NAMESPACE}
    ...    set_issue_details=Pods pending with reasons:\n"$_stdout" in the namespace ${NAMESPACE}
    ...    set_issue_next_steps=${next_steps}
    ...    _line__raise_issue_if_contains=-
    ${history}=    RW.CLI.Pop Shell History
    IF    """${pending_pods.stdout}""" == ""
        ${pending_pods}=    Set Variable    No pending pods found
    ELSE
        ${pending_pods}=    Set Variable    ${pending_pods.stdout}
    END
    RW.Core.Add Pre To Report    Summary of pendind pods in namespace: ${NAMESPACE}
    RW.Core.Add Pre To Report    ${pending_pods}
    RW.Core.Add Pre To Report    Commands Used:\n${history}

Troubleshoot Failed Pods In Namespace
    [Documentation]    Fetches all pods which are not running (unready) in the namespace and adds them to a report for future review.
    [Tags]    namespace    pods    status    unready    not starting    phase    failed
    ${unreadypods_details}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get pods --context=${CONTEXT} -n ${NAMESPACE} --field-selector=status.phase=Failed --no-headers -o json | jq -r --argjson exit_code_explanations '{"0": "Success", "1": "Error", "2": "Misconfiguration", "130": "Pod terminated by SIGINT", "134": "Abnormal Termination SIGABRT", "137": "Pod terminated by SIGKILL - Possible OOM", "143":"Graceful Termination SIGTERM"}' '.items[] | "---\\npod_name: \\(.metadata.name)\\nrestart_count: \\(.status.containerStatuses[0].restartCount // "N/A")\\nmessage: \\(.status.message // "N/A")\\nterminated_finishedAt: \\(.status.containerStatuses[0].state.terminated.finishedAt // "N/A")\\nexit_code: \\(.status.containerStatuses[0].state.terminated.exitCode // "N/A")\\nexit_code_explanation: \\($exit_code_explanations[.status.containerStatuses[0].state.terminated.exitCode | tostring] // "Unknown exit code")\\n---\\n"'
    ...    target_service=${kubectl}
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    render_in_commandlist=true
    ${next_steps}=    RW.NextSteps.Suggest    ${unreadypods_details.stdout}
    RW.CLI.Parse Cli Output By Line
    ...    rsp=${unreadypods_details}
    ...    set_severity_level=1
    ...    set_issue_expected=No pods should be in an unready state
    ...    set_issue_actual=We found the following unready pods: $_stdout
    ...    set_issue_title=Unready Pods Detected In Namespace ${NAMESPACE}
    ...    set_issue_details=Unready pods:\n"$_stdout" in the namespace ${NAMESPACE}
    ...    set_issue_next_steps=${next_steps}
    ...    _line__raise_issue_if_contains=-
    ${history}=    RW.CLI.Pop Shell History
    IF    """${unreadypods_details.stdout}""" == ""
        ${unreadypods_details}=    Set Variable    No unready pods found
    ELSE
        ${unreadypods_details}=    Set Variable    ${unreadypods_details.stdout}
    END
    RW.Core.Add Pre To Report    Summary of unready pods in namespace: ${NAMESPACE}
    RW.Core.Add Pre To Report    ${unreadypods_details}
    RW.Core.Add Pre To Report    Commands Used:\n${history}

Troubleshoot Workload Status Conditions In Namespace
    [Documentation]    Parses all workloads in a namespace and inspects their status conditions for issues. Status conditions with a status value of False are considered an error.
    [Tags]    namespace    status    conditions    pods    reasons    workloads
    ${all_resources}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get all --context ${CONTEXT} -n ${NAMESPACE} -o json
    ...    target_service=${kubectl}
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    render_in_commandlist=true
    ${workload_info}=    RW.CLI.Run Cli
    ...    cmd=cat << 'EOF' | jq -r '[.items[] | {kind: .kind, name: .metadata.name, conditions: .status.conditions[]? | select(.status == "False")}][0] // null'\n${all_resources.stdout}EOF
    ...    include_in_history=False
    ...    target_service=${kubectl}
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ${condition}=    RW.CLI.Run Cli
    ...    cmd=cat << 'EOF' | jq -r '.conditions.reason' | tr -d "\n"\n${workload_info.stdout}EOF
    ...    include_in_history=False
    ${workload_name}=    RW.CLI.Run Cli
    ...    cmd=cat << 'EOF' | jq -r '.name' | tr -d "\n"\n${workload_info.stdout}EOF
    ...    include_in_history=False
    ${workload_kind}=    RW.CLI.Run Cli
    ...    cmd=cat << 'EOF' | jq -r '.kind' | tr -d "\n"\n${workload_info.stdout}EOF
    ...    include_in_history=False
    ${next_steps}=    RW.NextSteps.Suggest    ${workload_kind.stdout} ${condition.stdout}
    ${next_steps}=    RW.NextSteps.Format    ${next_steps}
    ...    ${workload_kind.stdout}_name=${workload_name.stdout}
    ${failing_conditions}=    RW.CLI.Parse Cli Json Output
    ...    rsp=${all_resources}
    ...    extract_path_to_var__workload_conditions=items[].{kind:kind, name:metadata.name, conditions:status.conditions[?status == `False`]}
    ...    from_var_with_path__workload_conditions__to__failing_workload_conditions=[?length(conditions || `[]`) > `0`]
    ...    from_var_with_path__failing_workload_conditions__to__aggregate_failures=[].{kind:kind,name:name,conditions:conditions[].{reason:reason, type:type, status:status}}
    ...    from_var_with_path__aggregate_failures__to__pods_with_failures=length(@)
    ...    pods_with_failures__raise_issue_if_gt=0
    ...    set_severity_level=1
    ...    set_issue_title=$pods_with_failures Pods With Unhealthy Status In Namespace ${NAMESPACE}
    ...    set_issue_details=Pods with unhealthy status condition in the namespace ${NAMESPACE}. Here's a summary of potential issues we found:\n"$aggregate_failures"
    ...    set_issue_next_steps=${next_steps}
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

Get Listing Of Resources In Namespace
    [Documentation]    Simple fetch all to provide a snapshot of information about the workloads in the namespace for future review in a report.
    [Tags]    get all    resources    info    workloads    namespace    manifests
    ${all_results}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} api-resources --verbs=list --namespaced -o name --context=${CONTEXT} | xargs -n 1 ${KUBERNETES_DISTRIBUTION_BINARY} get --show-kind --ignore-not-found -n ${NAMESPACE} --context=${CONTEXT}
    ...    target_service=${kubectl}
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    render_in_commandlist=true
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Informational Get All for Namespace: ${NAMESPACE}
    RW.Core.Add Pre To Report    ${all_results.stdout}
    RW.Core.Add Pre To Report    Commands Used:\n${history}

Check For Namespace Event Anomalies
    [Documentation]    Parses all events in a namespace within a timeframe and checks for unusual activity, raising issues for any found.
    [Tags]    namespace    events    info    state    anomolies    count    occurences
    ${recent_anomalies}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get events --field-selector type!=Warning --context ${CONTEXT} -n ${NAMESPACE} -o json | jq -r '.items[] | select( .count / ( if ((.lastTimestamp|fromdate)-(.firstTimestamp|fromdate))/60 == 0 then 1 else ((.lastTimestamp|fromdate)-(.firstTimestamp|fromdate))/60 end ) > ${ANOMALY_THRESHOLD}) | "Event(s) Per Minute:" + (.count / ( if ((.lastTimestamp|fromdate)-(.firstTimestamp|fromdate))/60 == 0 then 1 else ((.lastTimestamp|fromdate)-(.firstTimestamp|fromdate))/60 end ) |tostring) +" Count:" + (.count|tostring) + " Minute(s):" + (((.lastTimestamp|fromdate)-(.firstTimestamp|fromdate))/60|tostring)+ " Object:" + .involvedObject.namespace + "/" + .involvedObject.kind + "/" + .involvedObject.name + " Reason:" + .reason + " Message:" + .message'
    ...    target_service=${kubectl}
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ${event_messages}=    RW.CLI.Run CLI
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get events --field-selector type!=Warning --context ${CONTEXT} -n ${NAMESPACE} -o json | jq -r .items[].message
    ...    target_service=${kubectl}
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    include_in_history=False
    ${event_messages}=    Evaluate    """${event_messages.stdout}""".split("\\n")
    ${pod_name}=    RW.CLI.Run Cli
    ...    cmd=echo "${recent_anomalies.stdout}" | grep -oP '(?<=Pod/)[^ ]*' | grep -oP '[^.]*(?=-[a-z0-9]+-[a-z0-9]+)' | head -n 1
    ...    include_in_history=False
    ${next_steps}=    RW.NextSteps.Suggest    ${event_messages}
    ${next_steps}=    RW.NextSteps.Format    ${next_steps}
    ...    pod_name=${pod_name.stdout}
    ...    deployment_name=${pod_name.stdout}
    RW.CLI.Parse Cli Output By Line
    ...    rsp=${recent_anomalies}
    ...    set_severity_level=2
    ...    set_issue_expected=No unusual recent anomaly events with high counts in the namespace ${NAMESPACE}
    ...    set_issue_actual=We detected events in the namespace ${NAMESPACE} which are considered anomalies
    ...    set_issue_title=Event Anomalies Detected In Namespace ${NAMESPACE}
    ...    set_issue_details=Anomaly non-warning events in namespace ${NAMESPACE}:\n"$_stdout"
    ...    set_issue_next_steps=${next_steps}
    ...    _line__raise_issue_if_contains=Object
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add To Report    Summary Of Anomalies Detected:\n
    RW.Core.Add To Report    ${recent_anomalies.stdout}\n
    RW.Core.Add Pre To Report    Commands Used:\n${history}

Troubleshoot Namespace Services And Application Workloads
    [Documentation]    Iterates through the services within a namespace for a given timeframe and byte length max, checking the resulting logs for distinct entries matching a given pattern in order to determine a root issue.
    [Tags]
    ...    namespace
    ...    services
    ...    applications
    ...    workloads
    ...    deployments
    ...    apps
    ...    ingress
    ...    http
    ...    networking
    ...    endpoints
    ...    logs
    ...    aggregate
    ...    filter
    ${aggregate_service_logs}=    RW.CLI.Run Cli
    ...    cmd=services=($(${KUBERNETES_DISTRIBUTION_BINARY} get svc -o=name --context=${CONTEXT} -n ${NAMESPACE})); logs=""; for service in "\${services[@]}"; do logs+=$(${KUBERNETES_DISTRIBUTION_BINARY} logs $service --limit-bytes=256000 --since=2h --context=${CONTEXT} -n ${NAMESPACE} | grep -Ei "${SERVICE_ERROR_PATTERN}" | grep -Ev "${SERVICE_EXCLUDE_PATTERN}" | sort | uniq -c | awk '{print "Issue Occurences:",$0}'); done; echo "\${logs}"
    ...    target_service=${kubectl}
    ...    env=${env}
    ...    secret_file__kubeconfig=${KUBECONFIG}
    ...    render_in_commandlist=true
    RW.CLI.Parse Cli Output By Line
    ...    rsp=${aggregate_service_logs}
    ...    set_severity_level=3
    ...    set_issue_expected=Service workload logs in namespace ${NAMESPACE} should not contain any error entries
    ...    set_issue_actual=Service workload logs in namespace ${NAMESPACE} contain errors entries
    ...    set_issue_title=Service Workloads In Namespace ${NAMESPACE} Have Error Log Entries
    ...    set_issue_details=We found the following distinctly counted errors in the service workloads of namespace ${NAMESPACE}:\n\n$_stdout\n\nThese errors may be related to other workloads that need triaging
    ...    set_issue_next_steps=Check For Deployment Event Anomalies
    ...    _line__raise_issue_if_contains=Error
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add To Report    Sample Of Aggregate Counted Logs Found:\n
    RW.Core.Add To Report    ${aggregate_service_logs.stdout}\n
    RW.Core.Add Pre To Report    Commands Used:\n${history}

Check Missing or Risky PodDisruptionBudget Policies
    [Documentation]    Searches through deployemnts and statefulsets to determine if they are missing PodDistruptionBudgets or have them configured in a risky way that prohibits cluster or node upgrades.
    [Tags]    poddisruptionbudget    availability    unavailable    risky    missing    policy    <service_name>
    ${pdb_check}=    RW.CLI.Run Cli
    ...    cmd=context="${CONTEXT}"; namespace="${NAMESPACE}"; check_health() { local type=$1; local name=$2; local replicas=$3; local selector=$4; local pdbs=$(${KUBERNETES_DISTRIBUTION_BINARY} --context "$context" --namespace "$namespace" get pdb -o json | jq -c --arg selector "$selector" '.items[] | select(.spec.selector.matchLabels | to_entries[] | .key + "=" + .value == $selector)'); if [[ $replicas -gt 1 && -z "$pdbs" ]]; then printf "%-30s %-30s %-10s\\n" "$type/$name" "" "Missing"; else echo "$pdbs" | jq -c . | while IFS= read -r pdb; do local pdbName=$(echo "$pdb" | jq -r '.metadata.name'); local minAvailable=$(echo "$pdb" | jq -r '.spec.minAvailable // ""'); local maxUnavailable=$(echo "$pdb" | jq -r '.spec.maxUnavailable // ""'); if [[ "$minAvailable" == "100%" || "$maxUnavailable" == "0" || "$maxUnavailable" == "0%" ]]; then printf "%-30s %-30s %-10s\\n" "$type/$name" "$pdbName" "Risky"; elif [[ $replicas -gt 1 && ("$minAvailable" != "100%" || "$maxUnavailable" != "0" || "$maxUnavailable" != "0%") ]]; then printf "%-30s %-30s %-10s\\n" "$type/$name" "$pdbName" "OK"; fi; done; fi; }; echo "Deployments:"; echo "-----------"; printf "%-30s %-30s %-10s\\n" "NAME" "PDB" "STATUS"; ${KUBERNETES_DISTRIBUTION_BINARY} --context "$context" --namespace "$namespace" get deployments -o json | jq -c '.items[] | "\\(.metadata.name) \\(.spec.replicas) \\(.spec.selector.matchLabels | to_entries[] | .key + "=" + .value)"' | while read -r line; do check_health "Deployment" $(echo $line | tr -d '"'); done; echo ""; echo "Statefulsets:"; echo "-------------"; printf "%-30s %-30s %-10s\\n" "NAME" "PDB" "STATUS"; ${KUBERNETES_DISTRIBUTION_BINARY} --context "$context" --namespace "$namespace" get statefulsets -o json | jq -c '.items[] | "\\(.metadata.name) \\(.spec.replicas) \\(.spec.selector.matchLabels | to_entries[] | .key + "=" + .value)"' | while read -r line; do check_health "StatefulSet" $(echo $line | tr -d '"'); done
    ...    target_service=${kubectl}
    ...    env=${env}
    ...    secret_file__kubeconfig=${KUBECONFIG}
    ...    render_in_commandlist=true
    ${risky_pdbs}=    RW.CLI.Run Cli
    ...    cmd=echo "${pdb_check.stdout}" | grep 'Risky' | cut -f 1 -d ' ' | awk -F'/' '{print $1, $2}'
    ...    include_in_history=False
    ${missing_pdbs}=    RW.CLI.Run Cli
    ...    cmd=echo "${pdb_check.stdout}" | grep 'Missing' | cut -f 1 -d ' ' | awk -F'/' '{print $1, $2}'
    ...    include_in_history=False
    RW.CLI.Parse Cli Output By Line
    ...    rsp=${pdb_check}
    ...    set_severity_level=2
    ...    set_issue_expected=PodDisruptionBudgets in ${NAMESPACE} should not block regular maintenance
    ...    set_issue_actual=We detected PodDisruptionBudgets in namespace ${NAMESPACE} which are considered Risky to maintenance operations
    ...    set_issue_title=Risky PodDisruptionBudgets Found in namespace ${NAMESPACE}
    ...    set_issue_details=Review the PodDisruptionBudget check for ${NAMESPACE}:\n$_stdout
    ...    set_issue_next_steps=Manually Validate & Fix PodDisruptionBudget for ${risky_pdbs.stdout}
    ...    _line__raise_issue_if_contains=(.*?)
    RW.CLI.Parse Cli Output By Line
    ...    rsp=${pdb_check}
    ...    set_severity_level=4
    ...    set_issue_expected=PodDisruptionBudgets in ${NAMESPACE} should exist for applications that have more than 1 replica
    ...    set_issue_actual=We detected Deployments or StatefulSets in namespace ${NAMESPACE} which are missing PodDisruptionBudgets
    ...    set_issue_title=Deployments or StatefulSets in namespace ${NAMESPACE} are missing PodDisruptionBudgets
    ...    set_issue_details=Review the Deployments and StatefulSets missing PodDisruptionBudget in ${NAMESPACE}:\n$_stdout
    ...    set_issue_next_steps=Manually create missing Pod Distruption Budgets for ${missing_pdbs.stdout}
    ...    _line__raise_issue_if_contains=Missing
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add To Report    ${pdb_check.stdout}\n
    RW.Core.Add Pre To Report    Commands Used:\n${history}


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
    ${ANOMALY_THRESHOLD}=    RW.Core.Import User Variable
    ...    ANOMALY_THRESHOLD
    ...    type=string
    ...    description=The rate of occurence per minute at which an Event becomes classified as an anomaly, even if Kubernetes considers it informational.
    ...    pattern=\d+(\.\d+)?
    ...    example=1.0
    ...    default=1.0
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
