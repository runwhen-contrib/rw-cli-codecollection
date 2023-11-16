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
Library             String

Suite Setup         Suite Initialization


*** Tasks ***
Trace And Troubleshoot Warning Events And Errors in Namespace `${NAMESPACE}`
    [Documentation]    Queries all error events in a given namespace within the last 30 minutes,
    ...    fetches the list of involved pod names, requests logs from them and parses
    ...    the logs for exceptions.
    [Tags]    namespace    trace    error    pods    events    logs    grep
    # get pods involved with error events
    ${error_events}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get events --field-selector type=Warning --context ${CONTEXT} -n ${NAMESPACE} -o json
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

Troubleshoot Container Restarts In Namespace `${NAMESPACE}`
    [Documentation]    Fetches pods that have container restarts and provides a report of the restart issues.
    [Tags]    namespace    containers    status    restarts
    ${container_restart_details}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get pods --context=${CONTEXT} -n ${NAMESPACE} -o json | jq -r --argjson exit_code_explanations '{"0": "Success", "1": "Error", "2": "Misconfiguration", "130": "Pod terminated by SIGINT", "134": "Abnormal Termination SIGABRT", "137": "Pod terminated by SIGKILL - Possible OOM", "143":"Graceful Termination SIGTERM"}' '.items[] | select(.status.containerStatuses != null) | select(any(.status.containerStatuses[]; .restartCount > 0)) | "---\\npod_name: \\(.metadata.name)\\n" + (.status.containerStatuses[] | "containers: \\(.name)\\nrestart_count: \\(.restartCount)\\nmessage: \\(.state.waiting.message // "N/A")\\nterminated_reason: \\(.lastState.terminated.reason // "N/A")\\nterminated_finishedAt: \\(.lastState.terminated.finishedAt // "N/A")\\nterminated_exitCode: \\(.lastState.terminated.exitCode // "N/A")\\nexit_code_explanation: \\($exit_code_explanations[.lastState.terminated.exitCode | tostring] // "Unknown exit code")") + "\\n---\\n"'
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    render_in_commandlist=true
    ${container_restart_analysis}=    RW.CLI.Run Bash File
    ...    bash_file=container_restarts.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ${recommendations}=    RW.CLI.Run Cli
    ...    cmd=echo "${container_restart_analysis.stdout}" | awk '/Recommended Next Steps:/ {flag=1; next} flag'
    ...    env=${env}
    ...    include_in_history=false
    RW.CLI.Parse Cli Output By Line
    ...    rsp=${container_restart_analysis}
    ...    set_severity_level=2
    ...    set_issue_expected=Containers should not be restarting.
    ...    set_issue_actual=We found the following containers with restarts: $_stdout
    ...    set_issue_title=Container Restarts Detected In Namespace ${NAMESPACE}
    ...    set_issue_details=${container_restart_analysis.stdout}
    ...    set_issue_next_steps=${recommendations.stdout}
    ...    _line__raise_issue_if_contains=Recommend
    ${history}=    RW.CLI.Pop Shell History
    IF    """${container_restart_details.stdout}""" == ""
        ${container_restart_details}=    Set Variable    No container restarts found
    ELSE
        ${container_restart_details}=    Set Variable    ${container_restart_details.stdout}
    END
    RW.Core.Add Pre To Report    Summary of unready container restarts in namespace: ${NAMESPACE}
    RW.Core.Add Pre To Report    ${container_restart_analysis.stdout}
    RW.Core.Add Pre To Report    Commands Used:\n${history}

Troubleshoot Pending Pods In Namespace `${NAMESPACE}`
    [Documentation]    Fetches pods that are pending and provides details.
    [Tags]    namespace    pods    status    pending
    ${pending_pods}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get pods --context=${CONTEXT} -n ${NAMESPACE} --field-selector=status.phase=Pending --no-headers -o json | jq -r '.items[] | "---\\npod_name: \\(.metadata.name)\\nstatus: \\(.status.phase // "N/A")\\nmessage: \\(.status.conditions[].message // "N/A")\\nreason: \\(.status.conditions[].reason // "N/A")\\ncontainerStatus: \\((.status.containerStatuses // [{}])[].state // "N/A")\\ncontainerMessage: \\((.status.containerStatuses // [{}])[].state?.waiting?.message // "N/A")\\ncontainerReason: \\((.status.containerStatuses // [{}])[].state?.waiting?.reason // "N/A")\\n---\\n"'
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

Troubleshoot Failed Pods In Namespace `${NAMESPACE}`
    [Documentation]    Fetches all pods which are not running (unready) in the namespace and adds them to a report for future review.
    [Tags]    namespace    pods    status    unready    not starting    phase    failed
    ${unreadypods_details}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get pods --context=${CONTEXT} -n ${NAMESPACE} --field-selector=status.phase=Failed --no-headers -o json | jq -r --argjson exit_code_explanations '{"0": "Success", "1": "Error", "2": "Misconfiguration", "130": "Pod terminated by SIGINT", "134": "Abnormal Termination SIGABRT", "137": "Pod terminated by SIGKILL - Possible OOM", "143":"Graceful Termination SIGTERM"}' '.items[] | "---\\npod_name: \\(.metadata.name)\\nrestart_count: \\(.status.containerStatuses[0].restartCount // "N/A")\\nmessage: \\(.status.message // "N/A")\\nterminated_finishedAt: \\(.status.containerStatuses[0].state.terminated.finishedAt // "N/A")\\nexit_code: \\(.status.containerStatuses[0].state.terminated.exitCode // "N/A")\\nexit_code_explanation: \\($exit_code_explanations[.status.containerStatuses[0].state.terminated.exitCode | tostring] // "Unknown exit code")\\n---\\n"'
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

Troubleshoot Workload Status Conditions In Namespace `${NAMESPACE}`
    [Documentation]    Parses all workloads in a namespace and inspects their status conditions for issues. Status conditions with a status value of False are considered an error.
    [Tags]    namespace    status    conditions    pods    reasons    workloads
    ${workload_info}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get all --context ${CONTEXT} -n ${NAMESPACE} -o json | jq -r '[.items[] | {kind: .kind, name: .metadata.name, conditions: .status.conditions[]? | select(.status == "False")}][0] // null' | jq -s '.'
    ...    include_in_history=True
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    render_in_commandlist=true
    ${object_list}=    Evaluate    json.loads(r'''${workload_info.stdout}''')    json
    IF    len(@{object_list}) > 0
        FOR    ${item}    IN    @{object_list}
            ${object_kind}=    RW.CLI.Run Cli
            ...    cmd=echo "${item["kind"]}"| sed 's/ *$//' | tr -d '\n'
            ...    env=${env}
            ...    include_in_history=False
            ${object_name}=    RW.CLI.Run Cli
            ...    cmd=echo "${item["name"]}" | sed 's/ *$//' | tr -d '\n'
            ...    env=${env}
            ...    include_in_history=False
            ${item_owner}=    RW.CLI.Run Bash File
            ...    bash_file=find_resource_owners.sh
            ...    cmd_overide=./find_resource_owners.sh ${object_kind.stdout} ${object_name.stdout} ${NAMESPACE} ${CONTEXT}
            ...    env=${env}
            ...    secret_file__kubeconfig=${kubeconfig}
            ...    include_in_history=False
            IF    len($item_owner.stdout) > 0
                ${owner_kind}    ${owner_name}=    Split String    ${item_owner.stdout}    ${SPACE}
                ${owner_name}=    Replace String    ${owner_name}    \n    ${EMPTY}
            ELSE
                ${owner_kind}    ${owner_name}=    Set Variable    ""
            END               
            ${item_next_steps}=    RW.CLI.Run Bash File
            ...    bash_file=workload_next_steps.sh
            ...    cmd_overide=./workload_next_steps.sh "${item["conditions"]["reason"]}" "${owner_kind}" "${owner_name}"
            ...    env=${env}
            ...    secret_file__kubeconfig=${kubeconfig}
            ...    include_in_history=False
            RW.Core.Add Issue
            ...    severity=4
            ...    expected=Objects should post a status of True in `${NAMESPACE}`
            ...    actual=Objects in `${NAMESPACE}` were found with a status of False - indicating one or more unhealthy components.
            ...    title= ${object_kind.stdout} `${object_name.stdout}` has posted a status of `"${item["conditions"]["reason"]}"`
            ...    reproduce_hint=View Commands Used in Report Output
            ...    details=${object_kind.stdout} `${object_name.stdout}` is owned by ${owner_kind} `${owner_name}` and has indicated an unhealthy status.\n${item}
            ...    next_steps=${item_next_steps.stdout}
        END
    END
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Summary of Pods with Failing Conditions in Namespace `${NAMESPACE}`
    RW.Core.Add Pre To Report    ${workload_info.stdout}
    RW.Core.Add Pre To Report    Commands Used:\n${history}

Get Listing Of Resources In Namespace `${NAMESPACE}`
    [Documentation]    Simple fetch all to provide a snapshot of information about the workloads in the namespace for future review in a report.
    [Tags]    get all    resources    info    workloads    namespace    manifests
    ${all_results}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} api-resources --verbs=list --namespaced -o name --context=${CONTEXT} | xargs -n 1 ${KUBERNETES_DISTRIBUTION_BINARY} get --show-kind --ignore-not-found -n ${NAMESPACE} --context=${CONTEXT}
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    render_in_commandlist=true
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Informational Get All for Namespace: ${NAMESPACE}
    RW.Core.Add Pre To Report    ${all_results.stdout}
    RW.Core.Add Pre To Report    Commands Used:\n${history}

Check Event Anomalies in Namespace `${NAMESPACE}`
    [Documentation]    Fetches non warning events in a namespace within a timeframe and checks for unusual activity, raising issues for any found.
    [Tags]    namespace    events    info    state    anomolies    count    occurences
    ## FIXME - the calculation of events per minute is still wrong and needs deeper inspection, akin to something like a histogram
    ${recent_events_by_object}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get events --field-selector type!=Warning --context ${CONTEXT} -n ${NAMESPACE} -o json > $HOME/events.json && cat $HOME/events.json | jq -r '[.items[] | {namespace: .involvedObject.namespace, kind: .involvedObject.kind, name: (.involvedObject.name | split("-")[0]), count: .count, firstTimestamp: .firstTimestamp, lastTimestamp: .lastTimestamp, reason: .reason, message: .message}] | group_by(.namespace, .kind, .name) | .[] | {(.[0].namespace + "/" + .[0].kind + "/" + .[0].name): {events: .}}' | jq -r --argjson threshold "${ANOMALY_THRESHOLD}" 'to_entries[] | {object: .key, oldest_timestamp: ([.value.events[] | .firstTimestamp] | min), most_recent_timestamp: (reduce .value.events[] as $event (.value.firstTimestamp; if ($event.lastTimestamp > .) then $event.lastTimestamp else . end)), events_per_minute: (reduce .value.events[] as $event (0; . + ($event.count / (((($event.lastTimestamp | fromdateiso8601) - ($event.firstTimestamp | fromdateiso8601)) / 60) | if . == 0 then 1 else . end))) | floor), total_events: (reduce .value.events[] as $event (0; . + $event.count)), summary_messages: [.value.events[] | .message] | unique | join("; ")} | select(.events_per_minute > $threshold)' | jq -s '.'
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    render_in_commandlist=true
    ${object_list}=    Evaluate    json.loads(r'''${recent_events_by_object.stdout}''')    json
    IF    len(@{object_list}) > 0
        FOR    ${item}    IN    @{object_list}
            ${object_kind}=    RW.CLI.Run Cli
            ...    cmd=echo "${item["object"]}" | awk -F"/" '{print $2}' | sed 's/ *$//' | tr -d '\n'
            ...    env=${env}
            ...    include_in_history=False
            ${object_short_name}=    RW.CLI.Run Cli
            ...    cmd=echo "${item["object"]}" | awk -F"/" '{print $3}' | sed 's/ *$//' | tr -d '\n'
            ...    env=${env}
            ...    include_in_history=False
            ${item_owner}=    RW.CLI.Run Bash File
            ...    bash_file=find_resource_owners.sh
            ...    cmd_overide=./find_resource_owners.sh ${object_kind.stdout} ${object_short_name.stdout} ${NAMESPACE} ${CONTEXT}
            ...    env=${env}
            ...    secret_file__kubeconfig=${kubeconfig}
            ...    include_in_history=False
            ${messages}=    Replace String    ${item["summary_messages"]}    "    ${EMPTY}
            ${owner_kind}    ${owner_name}=    Split String    ${item_owner.stdout}    ${SPACE}
            ${owner_name}=    Replace String    ${owner_name}    \n    ${EMPTY}
            ${item_next_steps}=    RW.CLI.Run Bash File
            ...    bash_file=anomaly_next_steps.sh
            ...    cmd_overide=./anomaly_next_steps.sh "${messages}" "${owner_kind}" "${owner_name}"
            ...    env=${env}
            ...    secret_file__kubeconfig=${kubeconfig}
            ...    include_in_history=False
            RW.Core.Add Issue
            ...    severity=4
            ...    expected=Normal events should not frequently repeat in `${NAMESPACE}`
            ...    actual=Frequently events may be repeating in `${NAMESPACE}` which could indicate potential issues.
            ...    title= ${owner_kind} `${owner_name}` generated ${item["events_per_minute"]} events within a 1m period and should be reviewed.
            ...    reproduce_hint=View Commands Used in Report Output
            ...    details=Item `${item["object"]}` generated a total of ${item["total_events"]} events, and up to ${item["events_per_minute"]} events within a 1m period.\nContaining some of the following messages and types:\n`${item["summary_messages"]}`
            ...    next_steps=${item_next_steps.stdout}
        END
    END

    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add To Report    Summary Of Anomalies Detected:\n
    RW.Core.Add To Report    ${recent_events_by_object.stdout}\n
    RW.Core.Add Pre To Report    Commands Used:\n${history}

Troubleshoot Services And Application Workloads in Namespace `${NAMESPACE}`
    [Documentation]    Iterates through the services within a namespace for a given timeframe and byte length max, checking the resulting logs for distinct entries matching a given pattern, provide a summary of which services require additional investigation.
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
    ...    cmd=services=($(${KUBERNETES_DISTRIBUTION_BINARY} get svc -o=name --context=${CONTEXT} -n ${NAMESPACE})) && [ \${#services[@]} -eq 0 ] && echo "No services found." || { > "logs.json"; for service in "\${services[@]}"; do ${KUBERNETES_DISTRIBUTION_BINARY} logs $service --limit-bytes=256000 --since=2h --context=${CONTEXT} -n ${NAMESPACE} 2>/dev/null | grep -Ei "${SERVICE_ERROR_PATTERN}" | grep -Ev "${SERVICE_EXCLUDE_PATTERN}" | while read -r line; do service_name="\${service#*/}"; message=$(echo "$line" | jq -aRs .); printf '{"service": "%s", "message": %s}\n' "\${service_name}" "$message" >> "logs.json"; done; done; [ ! -s "logs.json" ] && echo "No log entries found." || cat "logs.json" | jq -s '[ (group_by(.service) | map({service: .[0].service, total_logs: length})), (group_by(.service) | map({service: .[0].service, top_logs: (group_by(.message[0:200]) | map({message_start: .[0].message[0:200], count: length}) | sort_by(.count) | reverse | .[0:3])})) ] | add'; } > $HOME/output; cat $HOME/output
    ...    env=${env}
    ...    secret_file__kubeconfig=${KUBECONFIG}
    ...    render_in_commandlist=true
    ${services_with_errors}=    RW.CLI.Run Cli
    ...    cmd=jq -r '[ .[].service ] | unique[]' $HOME/output
    ...    env=${env}
    ...    secret_file__kubeconfig=${KUBECONFIG}
    ...    render_in_commandlist=false
    ...    include_in_history=false
    @{service_list}=    Split String    ${services_with_errors.stdout}
    FOR    ${service}    IN    @{service_list}
        ${service}=    Strip String    ${service}
        ${service}=    Replace String    ${service}    \n    ${EMPTY}
        ${service_owner}=    RW.CLI.Run Cli
        ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get endpoints "${service}" -n "${NAMESPACE}" --context="${CONTEXT}" -o jsonpath='{range .subsets[*].addresses[*]}{.targetRef.name}{"\\n"}{end}' | xargs -I {} sh -c 'owner_kind=$(${KUBERNETES_DISTRIBUTION_BINARY} get pod {} -n "${NAMESPACE}" --context="${CONTEXT}" -o=jsonpath="{.metadata.ownerReferences[0].kind}"); if [ "$owner_kind" = "ReplicaSet" ]; then replicaset=$(${KUBERNETES_DISTRIBUTION_BINARY} get pod {} -n "${NAMESPACE}" --context="${CONTEXT}" -o=jsonpath="{.metadata.ownerReferences[0].name}"); deployment_name=$(${KUBERNETES_DISTRIBUTION_BINARY} get replicaset $replicaset -n "${NAMESPACE}" --context="${CONTEXT}" -o=jsonpath="{.metadata.ownerReferences[0].name}"); echo "Deployment $deployment_name"; else owner_info=$($owner_kind ${KUBERNETES_DISTRIBUTION_BINARY} get pod {} -n "${NAMESPACE}" --context="${CONTEXT}" -o=jsonpath="{.metadata.ownerReferences[0].name}"); echo "$owner_info"; fi' | sort | uniq
        ...    secret_file__kubeconfig=${KUBECONFIG}
        ...    env=${env}
        ...    include_in_history=false
        ${owner_kind}    ${owner_name}=    Split String    ${service_owner.stdout}    ${SPACE}
        ${owner_name}=    Replace String    ${owner_name}    \n    ${EMPTY}
        ${total_logs}=    RW.CLI.Run Cli
        ...    cmd=jq '.[] | select(.service == "${service}") | .total_logs' $HOME/output
        ...    env=${env}
        ...    include_in_history=false
        ${logs_details}=    RW.CLI.Run Cli
        ...    cmd=jq -r '.[] | select(.service == "${service}") |.top_logs[]? | "\\(.message_start) \\(.count)"' $HOME/output
        ...    env=${env}
        ...    include_in_history=false
        RW.Core.Add Issue
        ...    severity=4
        ...    expected=Service `${service}` should not have error logs in associated pods in namespace `${NAMESPACE}`.
        ...    actual=Error logs were identified for service `${service}` in namespace `${NAMESPACE}`.
        ...    title=Service `${service}` has error logs in namespace `${NAMESPACE}`.
        ...    reproduce_hint=View Commands Used in Report Output
        ...    details=Total Logs: ${total_logs.stdout}\nTop Logs:\n${logs_details.stdout}
        ...    next_steps=Check ${owner_kind} Logs for Issues with `${owner_name}`
    END
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add To Report    Log Summary for Services in namespace `${NAMESPACE}`:\n
    RW.Core.Add To Report    ${aggregate_service_logs.stdout}\n
    RW.Core.Add Pre To Report    Commands Used:\n${history}

Check Missing or Risky PodDisruptionBudget Policies in Namepace `${NAMESPACE}`
    [Documentation]    Searches through deployemnts and statefulsets to determine if PodDistruptionBudgets are missing and/or are configured in a risky way that operational maintenance.
    [Tags]    poddisruptionbudget    availability    unavailable    risky    missing    policy    <service_name>
    ${pdb_check}=    RW.CLI.Run Cli
    ...    cmd=context="${CONTEXT}"; namespace="${NAMESPACE}"; check_health() { local type=$1; local name=$2; local replicas=$3; local selector=$4; local pdbs=$(${KUBERNETES_DISTRIBUTION_BINARY} --context "$context" --namespace "$namespace" get pdb -o json | jq -c --arg selector "$selector" '.items[] | select(.spec.selector.matchLabels | to_entries[] | .key + "=" + .value == $selector)'); if [[ $replicas -gt 1 && -z "$pdbs" ]]; then printf "%-30s %-30s %-10s\\n" "$type/$name" "" "Missing"; else echo "$pdbs" | jq -c . | while IFS= read -r pdb; do local pdbName=$(echo "$pdb" | jq -r '.metadata.name'); local minAvailable=$(echo "$pdb" | jq -r '.spec.minAvailable // ""'); local maxUnavailable=$(echo "$pdb" | jq -r '.spec.maxUnavailable // ""'); if [[ "$minAvailable" == "100%" || "$maxUnavailable" == "0" || "$maxUnavailable" == "0%" ]]; then printf "%-30s %-30s %-10s\\n" "$type/$name" "$pdbName" "Risky"; elif [[ $replicas -gt 1 && ("$minAvailable" != "100%" || "$maxUnavailable" != "0" || "$maxUnavailable" != "0%") ]]; then printf "%-30s %-30s %-10s\\n" "$type/$name" "$pdbName" "OK"; fi; done; fi; }; echo "Deployments:"; echo "-----------"; printf "%-30s %-30s %-10s\\n" "NAME" "PDB" "STATUS"; ${KUBERNETES_DISTRIBUTION_BINARY} --context "$context" --namespace "$namespace" get deployments -o json | jq -c '.items[] | "\\(.metadata.name) \\(.spec.replicas) \\(.spec.selector.matchLabels | to_entries[] | .key + "=" + .value)"' | while read -r line; do check_health "Deployment" $(echo $line | tr -d '"'); done; echo ""; echo "Statefulsets:"; echo "-------------"; printf "%-30s %-30s %-10s\\n" "NAME" "PDB" "STATUS"; ${KUBERNETES_DISTRIBUTION_BINARY} --context "$context" --namespace "$namespace" get statefulsets -o json | jq -c '.items[] | "\\(.metadata.name) \\(.spec.replicas) \\(.spec.selector.matchLabels | to_entries[] | .key + "=" + .value)"' | while read -r line; do check_health "StatefulSet" $(echo $line | tr -d '"'); done
    ...    env=${env}
    ...    secret_file__kubeconfig=${KUBECONFIG}
    ...    render_in_commandlist=true
    ${risky_pdbs}=    RW.CLI.Run Cli
    ...    cmd=echo "${pdb_check.stdout}" | grep 'Risky' | cut -f 1 -d ' ' | sed 's/^ *//; s/ *$//' | awk -F'/' '{ gsub(/^ *| *$/, "", $1); gsub(/^ *| *$/, "", $2); print $1 "/" $2 }' | sed 's/ *$//' | tr -d '\n'
    ...    include_in_history=False
    ${missing_pdbs}=    RW.CLI.Run Cli
    ...    cmd=echo "${pdb_check.stdout}" | grep 'Missing' | cut -f 1 -d ' ' | sed 's/^ *//; s/ *$//' | awk -F'/' '{ gsub(/^ *| *$/, "", $1); gsub(/^ *| *$/, "", $2); print $1 "/" $2 }' | sed 's/ *$//' | tr -d '\n'
    ...    include_in_history=False
    # Raise Issues on Missing PDBS
    IF    len($missing_pdbs.stdout) > 0
        @{missing_pdb_list}=    Create List    ${missing_pdbs.stdout}
        FOR    ${missing_pdb}    IN    @{missing_pdb_list}
            RW.Core.Add Issue
            ...    severity=4
            ...    expected=PodDisruptionBudgets in namespace `${NAMESPACE}` should exist for applications that have more than 1 replica
            ...    actual=We detected Deployments or StatefulSets in namespace `${NAMESPACE}` which are missing PodDisruptionBudgets
            ...    title=PodDisruptionBudget missing for `${missing_pdb}` in namespace `${NAMESPACE}`
            ...    reproduce_hint=View Commands Used in Report Output
            ...    details=${pdb_check.stdout}
            ...    next_steps=Create missing PodDistruptionBudgets for `${missing_pdb}`
        END
    END
    # Raise issues on Risky PDBS
    IF    len($risky_pdbs.stdout) > 0
        @{risky_pdb_list}=    Create List    ${risky_pdbs.stdout}
        FOR    ${risky_pdb}    IN    @{risky_pdb_list}
            RW.Core.Add Issue
            ...    severity=4
            ...    expected=PodDisruptionBudgets in `${NAMESPACE}` should not block regular maintenance
            ...    actual=PodDisruptionBudgets in namespace `${NAMESPACE}` are considered Risky to maintenance operations.
            ...    title=PodDisruptionBudget configured for `${risky_pdb}` in namespace `${NAMESPACE}` could be a risk.
            ...    reproduce_hint=View Commands Used in Report Output
            ...    details=${pdb_check.stdout}
            ...    next_steps=Review PodDisruptionBudget for `${risky_pdb}` to ensure it does allows pods to be evacuated and rescheduled during maintenance periods.
        END
    END
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
    ...    default=5.0
    ${KUBERNETES_DISTRIBUTION_BINARY}=    RW.Core.Import User Variable    KUBERNETES_DISTRIBUTION_BINARY
    ...    type=string
    ...    description=Which binary to use for Kubernetes CLI commands.
    ...    enum=[kubectl,oc]
    ...    example=kubectl
    ...    default=kubectl
    ${HOME}=    RW.Core.Import User Variable    HOME
    Set Suite Variable    ${kubeconfig}    ${kubeconfig}
    Set Suite Variable    ${kubectl}    ${kubectl}
    Set Suite Variable    ${CONTEXT}    ${CONTEXT}
    Set Suite Variable    ${KUBERNETES_DISTRIBUTION_BINARY}    ${KUBERNETES_DISTRIBUTION_BINARY}
    Set Suite Variable    ${NAMESPACE}    ${NAMESPACE}
    Set Suite Variable    ${ERROR_PATTERN}    ${ERROR_PATTERN}
    Set Suite Variable    ${ANOMALY_THRESHOLD}    ${ANOMALY_THRESHOLD}
    Set Suite Variable    ${SERVICE_ERROR_PATTERN}    ${SERVICE_ERROR_PATTERN}
    Set Suite Variable    ${SERVICE_EXCLUDE_PATTERN}    ${SERVICE_EXCLUDE_PATTERN}
    Set Suite Variable    ${HOME}    ${HOME}
    Set Suite Variable
    ...    ${env}
    ...    {"KUBECONFIG":"./${kubeconfig.key}", "KUBERNETES_DISTRIBUTION_BINARY":"${KUBERNETES_DISTRIBUTION_BINARY}", "CONTEXT":"${CONTEXT}", "NAMESPACE":"${NAMESPACE}", "HOME":"${HOME}"}
