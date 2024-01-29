*** Settings ***
Documentation       This taskset runs general troubleshooting checks against all applicable objects in a namespace. Looks for warning events, odd or frequent normal events, restarting containers and failed or pending pods.
Metadata            Author    stewartshea
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
Troubleshoot Warning Events in Namespace `${NAMESPACE}`
    [Documentation]    Queries all warning events in a given namespace within the last 30 minutes,
    ...    fetches the list of involved pod names, groups the events, collects event message details
    ...    and searches for a useful next step based on these details.
    [Tags]    namespace    trace    error    pods    events    logs    grep    ${NAMESPACE}
    ${warning_events_by_object}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get events --field-selector type=Warning --context ${CONTEXT} -n ${NAMESPACE} -o json > $HOME/warning_events.json && cat $HOME/warning_events.json | jq -r '[.items[] | {namespace: .involvedObject.namespace, kind: .involvedObject.kind, baseName: ((if .involvedObject.kind == "Pod" then (.involvedObject.name | split("-")[:-1] | join("-")) else .involvedObject.name end) // ""), count: .count, firstTimestamp: .firstTimestamp, lastTimestamp: .lastTimestamp, reason: .reason, message: .message}] | group_by(.namespace, .kind, .baseName) | map({object: (.[0].namespace + "/" + .[0].kind + "/" + .[0].baseName), total_events: (reduce .[] as $event (0; . + $event.count)), summary_messages: (map(.message) | unique | join("; ")), oldest_timestamp: (map(.firstTimestamp) | sort | first), most_recent_timestamp: (map(.lastTimestamp) | sort | last)}) | map(select((now - ((.most_recent_timestamp | fromdateiso8601)))/60 <= 30))'
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    show_in_rwl_cheatsheet=true
    ...    render_in_commandlist=true
    ${object_list}=    Evaluate    json.loads(r'''${warning_events_by_object.stdout}''')    json
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
            # FIXME Theres a case where the object generating the event is gone. We need to figure out how
            # to best handle this case instead of "Unknown" "unknown"
            ${item_owner}=    RW.CLI.Run Bash File
            ...    bash_file=find_resource_owners.sh
            ...    cmd_override=./find_resource_owners.sh ${object_kind.stdout} ${object_short_name.stdout} ${NAMESPACE} ${CONTEXT}
            ...    env=${env}
            ...    secret_file__kubeconfig=${kubeconfig}
            ...    include_in_history=False
            ${messages}=    Replace String    ${item["summary_messages"]}    "    ${EMPTY}
            ${item_owner_output}=    RW.CLI.Run Cli
            ...    cmd=echo "${item_owner.stdout}" | sed 's/ *$//' | tr -d '\n'
            ...    env=${env}
            ...    include_in_history=False
            IF    len($item_owner_output.stdout) > 0 and ($item_owner_output.stdout) != "No resource found"
                ${owner_kind}    ${owner_name}=    Split String    ${item_owner_output.stdout}    ${SPACE}
                ${owner_name}=    Replace String    ${owner_name}    \n    ${EMPTY}
            ELSE
                ${owner_kind}=    Set Variable    "Unknown"
                ${owner_name}=    Set Variable    "Unknown"
            END
            ${item_next_steps}=    RW.CLI.Run Bash File
            ...    bash_file=workload_next_steps.sh
            ...    cmd_override=./workload_next_steps.sh "${messages}" "${owner_kind}" "${owner_name}"
            ...    env=${env}
            ...    secret_file__kubeconfig=${kubeconfig}
            ...    include_in_history=False
            RW.Core.Add Issue
            ...    severity=3
            ...    expected=Warning events should not be present in namespace `${NAMESPACE}` for ${owner_kind} `${owner_name}`
            ...    actual=Warning events are found in namespace `${NAMESPACE}` for ${owner_kind} `${owner_name}` which indicate potential issues.
            ...    title= ${owner_kind} `${owner_name}` generated ${item["total_events"]} **warning** events and should be reviewed.
            ...    reproduce_hint=View Commands Used in Report Output
            ...    details=Item `${item["object"]}` generated a total of ${item["total_events"]} events containing some of the following messages and types:\n`${item["summary_messages"]}`
            ...    next_steps=${item_next_steps.stdout}
        END
    END
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Summary of Warning events in namespace: ${NAMESPACE}
    RW.Core.Add Pre To Report    ${warning_events_by_object.stdout}
    RW.Core.Add Pre To Report    Commands Used:\n${history}

Troubleshoot Container Restarts In Namespace `${NAMESPACE}`
    [Documentation]    Fetches pods that have container restarts and provides a report of the restart issues.
    [Tags]    namespace    containers    status    restarts    ${NAMESPACE}
    ${container_restart_details}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get pods --context=${CONTEXT} -n ${NAMESPACE} -o json | jq -r --argjson exit_code_explanations '{"0": "Success", "1": "Error", "2": "Misconfiguration", "130": "Pod terminated by SIGINT", "134": "Abnormal Termination SIGABRT", "137": "Pod terminated by SIGKILL - Possible OOM", "143":"Graceful Termination SIGTERM"}' '.items[] | select(.status.containerStatuses != null) | select(any(.status.containerStatuses[]; .restartCount > 0)) | "---\\npod_name: \\(.metadata.name)\\n" + (.status.containerStatuses[] | "containers: \\(.name)\\nrestart_count: \\(.restartCount)\\nmessage: \\(.state.waiting.message // "N/A")\\nterminated_reason: \\(.lastState.terminated.reason // "N/A")\\nterminated_finishedAt: \\(.lastState.terminated.finishedAt // "N/A")\\nterminated_exitCode: \\(.lastState.terminated.exitCode // "N/A")\\nexit_code_explanation: \\($exit_code_explanations[.lastState.terminated.exitCode | tostring] // "Unknown exit code")") + "\\n---\\n"'
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    show_in_rwl_cheatsheet=true
    ...    render_in_commandlist=true
    ${container_restart_analysis}=    RW.CLI.Run Bash File
    ...    bash_file=container_restarts.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ${recommendations}=    RW.CLI.Run Cli
    ...    cmd=echo '${container_restart_analysis.stdout}' | awk '/Recommended Next Steps:/ {flag=1; next} flag'
    ...    env=${env}
    ...    include_in_history=false
    RW.CLI.Parse Cli Output By Line
    ...    rsp=${container_restart_analysis}
    ...    set_severity_level=2
    ...    set_issue_expected=Containers should not be restarting in namespace `${NAMESPACE}`
    ...    set_issue_actual=We found containers with restarts in namespace `${NAMESPACE}`
    ...    set_issue_title=Container Restarts Detected In Namespace `${NAMESPACE}`
    ...    set_issue_reproduce_hint=View Commands Used in Report Output
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
    [Tags]    namespace    pods    status    pending    ${NAMESPACE}
    ${pending_pods}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get pods --context=${CONTEXT} -n ${NAMESPACE} --field-selector=status.phase=Pending --no-headers -o json | jq -r '.items[] | "pod_name: \\(.metadata.name)\\nstatus: \\(.status.phase // "N/A")\\nmessage: \\(.status.conditions[0].message // "N/A")\\nreason: \\(.status.conditions[0].reason // "N/A")\\ncontainerStatus: \\((.status.containerStatuses[0].state // "N/A"))\\ncontainerMessage: \\(.status.containerStatuses[0].state.waiting?.message // "N/A")\\ncontainerReason: \\(.status.containerStatuses[0].state.waiting?.reason // "N/A")\\n_______-"'
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    show_in_rwl_cheatsheet=true
    ...    render_in_commandlist=true
    ${pendind_pod_list}=    Split String    ${pending_pods.stdout}    _______-
    IF    len($pendind_pod_list) > 0
        FOR    ${item}    IN    @{pendind_pod_list}
            ${is_not_just_newline}=    Evaluate    '''${item}'''.strip() != ''
            IF    ${is_not_just_newline}
                ${pod_name}=    RW.CLI.Run Cli
                ...    cmd=echo '${item}' | grep pod_name: | sed 's/^pod_name: //' | sed 's/ *$//' | tr -d '\n'
                ...    env=${env}
                ...    include_in_history=false
                ${pod_message}=    RW.CLI.Run Cli
                ...    cmd=echo '${item}' | grep message: | sed 's/^message: //' | sed 's/ *$//' | tr -d '\n'| sed 's/\"//g'
                ...    env=${env}
                ...    include_in_history=false
                ${container_message}=    RW.CLI.Run Cli
                ...    cmd=echo '${item}' | grep containerMessage: | sed 's/^containerMessage: //' | sed 's/ *$//' | tr -d '\n'| sed 's/\"//g'
                ...    env=${env}
                ...    include_in_history=false
                ${container_reason}=    RW.CLI.Run Cli
                ...    cmd=echo '${item}' | grep containerReason: | sed 's/^containerReason: //' | sed 's/ *$//' | tr -d '\n'| sed 's/\"//g'
                ...    env=${env}
                ...    include_in_history=false
                ${item_owner}=    RW.CLI.Run Bash File
                ...    bash_file=find_resource_owners.sh
                ...    cmd_override=./find_resource_owners.sh Pod ${pod_name.stdout} ${NAMESPACE} ${CONTEXT}
                ...    env=${env}
                ...    secret_file__kubeconfig=${kubeconfig}
                ...    include_in_history=False
                ${item_owner_output}=    RW.CLI.Run Cli
                ...    cmd=echo "${item_owner.stdout}" | sed 's/ *$//' | tr -d '\n'
                ...    env=${env}
                ...    include_in_history=False
                IF    len($item_owner_output.stdout) > 0 and ($item_owner_output.stdout) != "No resource found"
                    ${owner_kind}    ${owner_name}=    Split String    ${item_owner_output.stdout}    ${SPACE}
                    ${owner_name}=    Replace String    ${owner_name}    \n    ${EMPTY}
                ELSE
                    ${owner_kind}=    Set Variable    "Unknown"
                    ${owner_name}=    Set Variable    "Unknown"
                END
                ${item_next_steps}=    RW.CLI.Run Bash File
                ...    bash_file=workload_next_steps.sh
                ...    cmd_override=./workload_next_steps.sh "${container_reason.stdout};${pod_message.stdout};${container_reason.stdout}" "${owner_kind}" "${owner_name}"
                ...    env=${env}
                ...    secret_file__kubeconfig=${kubeconfig}
                ...    include_in_history=False
                RW.Core.Add Issue
                ...    severity=2
                ...    expected=Pods should not be pending in `${NAMESPACE}`.
                ...    actual=Pod `${pod_name.stdout}` in `${NAMESPACE}` is pending.
                ...    title= Pod `${pod_name.stdout}` is pending with ${container_reason.stdout}
                ...    reproduce_hint=View Commands Used in Report Output
                ...    details=Pod `${pod_name.stdout}` is owned by ${owner_kind} `${owner_name}` and is pending with the following details:\n${item}
                ...    next_steps=${item_next_steps.stdout}
            END
        END
    END
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Summary of pendind pods in namespace: ${NAMESPACE}
    RW.Core.Add Pre To Report    ${pending_pods.stdout}
    RW.Core.Add Pre To Report    Commands Used:\n${history}

Troubleshoot Failed Pods In Namespace `${NAMESPACE}`
    [Documentation]    Fetches all pods which are not running (unready) in the namespace and adds them to a report for future review.
    [Tags]    namespace    pods    status    unready    not starting    phase    failed    ${NAMESPACE}
    ${unreadypods_details}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get pods --context=${CONTEXT} -n ${NAMESPACE} --field-selector=status.phase=Failed --no-headers -o json | jq -r --argjson exit_code_explanations '{"0": "Success", "1": "Error", "2": "Misconfiguration", "130": "Pod terminated by SIGINT", "134": "Abnormal Termination SIGABRT", "137": "Pod terminated by SIGKILL - Possible OOM", "143":"Graceful Termination SIGTERM"}' '.items[] | "pod_name: \\(.metadata.name)\\nrestart_count: \\(.status.containerStatuses[0].restartCount // "N/A")\\nmessage: \\(.status.message // "N/A")\\nterminated_finishedAt: \\(.status.containerStatuses[0].state.terminated.finishedAt // "N/A")\\nexit_code: \\(.status.containerStatuses[0].state.terminated.exitCode // "N/A")\\nexit_code_explanation: \\($exit_code_explanations[.status.containerStatuses[0].state.terminated.exitCode | tostring] // "Unknown exit code")\\n_______-"'
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    show_in_rwl_cheatsheet=true
    ...    render_in_commandlist=true
    ${unready_pods_list}=    Split String    ${unreadypods_details.stdout}    _______-
    IF    len($unready_pods_list) > 0
        FOR    ${item}    IN    @{unready_pods_list}
            ${is_not_just_newline}=    Evaluate    '''${item}'''.strip() != ''
            IF    ${is_not_just_newline}
                ${pod_name}=    RW.CLI.Run Cli
                ...    cmd=echo '${item}' | grep pod_name: | sed 's/^pod_name: //' | sed 's/ *$//' | tr -d '\n'
                ...    env=${env}
                ...    include_in_history=false
                ${pod_message}=    RW.CLI.Run Cli
                ...    cmd=echo '${item}' | grep message: | sed 's/^message: //' | sed 's/ *$//' | tr -d '\n'| sed 's/\"//g'
                ...    env=${env}
                ...    include_in_history=false
                ${container_message}=    RW.CLI.Run Cli
                ...    cmd=echo '${item}' | grep containerMessage: | sed 's/^containerMessage: //' | sed 's/ *$//' | tr -d '\n'| sed 's/\"//g'
                ...    env=${env}
                ...    include_in_history=false
                ${exit_code_explanation}=    RW.CLI.Run Cli
                ...    cmd=echo '${item}' | grep exit_code_explanation: | sed 's/^exit_code_explanation: //' | sed 's/ *$//' | tr -d '\n'| sed 's/\"//g'
                ...    env=${env}
                ...    include_in_history=false
                ${item_owner}=    RW.CLI.Run Bash File
                ...    bash_file=find_resource_owners.sh
                ...    cmd_override=./find_resource_owners.sh Pod ${pod_name.stdout} ${NAMESPACE} ${CONTEXT}
                ...    env=${env}
                ...    secret_file__kubeconfig=${kubeconfig}
                ...    include_in_history=False
                ${item_owner_output}=    RW.CLI.Run Cli
                ...    cmd=echo "${item_owner.stdout}" | sed 's/ *$//' | tr -d '\n'
                ...    env=${env}
                ...    include_in_history=False
                IF    len($item_owner_output.stdout) > 0 and ($item_owner_output.stdout) != "No resource found"
                    ${owner_kind}    ${owner_name}=    Split String    ${item_owner_output.stdout}    ${SPACE}
                    ${owner_name}=    Replace String    ${owner_name}    \n    ${EMPTY}
                ELSE
                    ${owner_kind}=    Set Variable    "Unknown"
                    ${owner_name}=    Set Variable    "Unknown"
                END
                ${item_next_steps}=    RW.CLI.Run Bash File
                ...    bash_file=workload_next_steps.sh
                ...    cmd_override=./workload_next_steps.sh "${container_message.stdout};${pod_message.stdout}" "${owner_kind}" "${owner_name}"
                ...    env=${env}
                ...    secret_file__kubeconfig=${kubeconfig}
                ...    include_in_history=False
                RW.Core.Add Issue
                ...    severity=2
                ...    expected=No pods should be in an unready state in namespace `${NAMESPACE}`.
                ...    actual=Pod `${pod_name.stdout}` in `${NAMESPACE}` is NotReady or Failed.
                ...    title= Pod `${pod_name.stdout}` exited with ${exit_code_explanation.stdout}
                ...    reproduce_hint=View Commands Used in Report Output
                ...    details=Pod `${pod_name.stdout}` is owned by ${owner_kind} `${owner_name}` and is pending with the following details:\n${item}
                ...    next_steps=${item_next_steps.stdout}
            END
        END
    END
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
    [Tags]    namespace    status    conditions    pods    reasons    workloads    ${NAMESPACE}
    ${workload_info}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get pods --context ${CONTEXT} -n ${NAMESPACE} -o json | jq -r '.items[] | select(.status.conditions[]? | select(.type == "Ready" and .status == "False" and .reason != "PodCompleted")) | {kind: .kind, name: .metadata.name, conditions: .status.conditions}' | jq -s '.'
    ...    include_in_history=True
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    show_in_rwl_cheatsheet=true
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
            ${object_status_string}=    RW.CLI.Run Cli
            ...    cmd=echo "${item["conditions"]}" | sed 's/True/true/g; s/False/false/g; s/None/null/g; s/'\\''/\"/g'
            ...    env=${env}
            ...    include_in_history=False
            ${object_status}=    RW.CLI.Run Cli
            ...    cmd=echo '${object_status_string.stdout}' | jq -r '.[] | select(.type == "Ready") | if .message then .message else .reason end' | sed 's/ *$//' | tr -d '\n'
            ...    env=${env}
            ...    include_in_history=False
            ${item_owner}=    RW.CLI.Run Bash File
            ...    bash_file=find_resource_owners.sh
            ...    cmd_override=./find_resource_owners.sh ${object_kind.stdout} ${object_name.stdout} ${NAMESPACE} ${CONTEXT}
            ...    env=${env}
            ...    secret_file__kubeconfig=${kubeconfig}
            ...    include_in_history=False
            ${item_owner_output}=    RW.CLI.Run Cli
            ...    cmd=echo "${item_owner.stdout}" | sed 's/ *$//' | tr -d '\n'
            ...    env=${env}
            ...    include_in_history=False
            # FIXME: There's an odd condition where a pod with a name like this: jx-preview-gc-jobs-28337580-464vm produces no matches
            # as it's disappered, but events still linger. Need to catch this error later and validate a fix
            IF    len($item_owner_output.stdout) > 0 and ($item_owner_output.stdout) != "No resource found"
                ${owner_kind}    ${owner_name}=    Split String    ${item_owner_output.stdout}    ${SPACE}
                ${owner_name}=    Replace String    ${owner_name}    \n    ${EMPTY}
            ELSE
                ${owner_kind}=    Set Variable    "Unknown"
                ${owner_name}=    Set Variable    "Unknown"
            END
            ${item_next_steps}=    RW.CLI.Run Bash File
            ...    bash_file=workload_next_steps.sh
            ...    cmd_override=./workload_next_steps.sh "${item["conditions"]}" "${owner_kind}" "${owner_name}"
            ...    env=${env}
            ...    secret_file__kubeconfig=${kubeconfig}
            ...    include_in_history=False
            RW.Core.Add Issue
            ...    severity=4
            ...    expected=Objects should post a status of True in `${NAMESPACE}`
            ...    actual=Objects in `${NAMESPACE}` were found with a status of False - indicating one or more unhealthy components.
            ...    title= ${object_kind.stdout} `${object_name.stdout}` has posted a status of: ${object_status.stdout}
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
    [Tags]    get all    resources    info    workloads    namespace    manifests    ${namespace}
    ${all_results}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} api-resources --verbs=list --namespaced -o name --context=${CONTEXT} | xargs -n 1 ${KUBERNETES_DISTRIBUTION_BINARY} get --show-kind --ignore-not-found -n ${NAMESPACE} --context=${CONTEXT}
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    show_in_rwl_cheatsheet=true
    ...    render_in_commandlist=true
    ...    timeout_seconds=180
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Informational Get All for Namespace: ${NAMESPACE}
    RW.Core.Add Pre To Report    ${all_results.stdout}
    RW.Core.Add Pre To Report    Commands Used:\n${history}

Check Event Anomalies in Namespace `${NAMESPACE}`
    [Documentation]    Fetches non warning events in a namespace within a timeframe and checks for unusual activity, raising issues for any found.
    [Tags]    namespace    events    info    state    anomolies    count    occurences    ${NAMESPACE}
    ## FIXME - the calculation of events per minute is still wrong and needs deeper inspection, akin to something like a histogram
    ${recent_events_by_object}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get events --field-selector type!=Warning --context ${CONTEXT} -n ${NAMESPACE} -o json > $HOME/events.json && cat $HOME/events.json | jq -r '[.items[] | {namespace: .involvedObject.namespace, kind: .involvedObject.kind, name: ((if .involvedObject and .involvedObject.kind == "Pod" then (.involvedObject.name | split("-")[:-1] | join("-")) else .involvedObject.name end) // ""), count: .count, firstTimestamp: .firstTimestamp, lastTimestamp: .lastTimestamp, reason: .reason, message: .message}] | group_by(.namespace, .kind, .name) | .[] | {(.[0].namespace + "/" + .[0].kind + "/" + .[0].name): {events: .}}' | jq -r --argjson threshold "${ANOMALY_THRESHOLD}" 'to_entries[] | {object: .key, oldest_timestamp: ([.value.events[] | .firstTimestamp] | min), most_recent_timestamp: (reduce .value.events[] as $event (.value.firstTimestamp; if ($event.lastTimestamp > .) then $event.lastTimestamp else . end)), events_per_minute: (reduce .value.events[] as $event (0; . + ($event.count / (((($event.lastTimestamp | fromdateiso8601) - ($event.firstTimestamp | fromdateiso8601)) / 60) | if . == 0 then 1 else . end))) | floor), total_events: (reduce .value.events[] as $event (0; . + $event.count)), summary_messages: [.value.events[] | .message] | unique | join("; ")} | select(.events_per_minute > $threshold)' | jq -s '.'
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    show_in_rwl_cheatsheet=true
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
            ...    cmd_override=./find_resource_owners.sh ${object_kind.stdout} ${object_short_name.stdout} ${NAMESPACE} ${CONTEXT}
            ...    env=${env}
            ...    secret_file__kubeconfig=${kubeconfig}
            ...    include_in_history=False
            ${messages}=    Replace String    ${item["summary_messages"]}    "    ${EMPTY}
            ${item_owner_output}=    RW.CLI.Run Cli
            ...    cmd=echo "${item_owner.stdout}" | sed 's/ *$//' | tr -d '\n'
            ...    env=${env}
            ...    include_in_history=False
            IF    len($item_owner_output.stdout) > 0 and ($item_owner_output.stdout) != "No resource found"
                ${owner_kind}    ${owner_name}=    Split String    ${item_owner_output.stdout}    ${SPACE}
                ${owner_name}=    Replace String    ${owner_name}    \n    ${EMPTY}
            ELSE
                ${owner_kind}=    Set Variable    "Unknown"
                ${owner_name}=    Set Variable    "Unknown"
            END
            ${item_next_steps}=    RW.CLI.Run Bash File
            ...    bash_file=anomaly_next_steps.sh
            ...    cmd_override=./anomaly_next_steps.sh "${messages}" "${owner_kind}" "${owner_name}"
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

Check Missing or Risky PodDisruptionBudget Policies in Namepace `${NAMESPACE}`
    [Documentation]    Searches through deployemnts and statefulsets to determine if PodDistruptionBudgets are missing and/or are configured in a risky way that operational maintenance.
    [Tags]
    ...    poddisruptionbudget
    ...    pdb
    ...    maintenance
    ...    availability
    ...    unavailable
    ...    risky
    ...    missing
    ...    policy
    ...    ${NAMESPACE}
    ${pdb_check}=    RW.CLI.Run Cli
    ...    cmd=context="${CONTEXT}"; namespace="${NAMESPACE}"; check_health() { local type=$1; local name=$2; local replicas=$3; local selector=$4; local pdbs=$(${KUBERNETES_DISTRIBUTION_BINARY} --context "$context" --namespace "$namespace" get pdb -o json | jq -c --arg selector "$selector" '.items[] | select(.spec.selector.matchLabels | to_entries[] | .key + "=" + .value == $selector)'); if [[ $replicas -gt 1 && -z "$pdbs" ]]; then printf "%-30s %-30s %-10s\\n" "$type/$name" "" "Missing"; else echo "$pdbs" | jq -c . | while IFS= read -r pdb; do local pdbName=$(echo "$pdb" | jq -r '.metadata.name'); local minAvailable=$(echo "$pdb" | jq -r '.spec.minAvailable // ""'); local maxUnavailable=$(echo "$pdb" | jq -r '.spec.maxUnavailable // ""'); if [[ "$minAvailable" == "100%" || "$maxUnavailable" == "0" || "$maxUnavailable" == "0%" ]]; then printf "%-30s %-30s %-10s\\n" "$type/$name" "$pdbName" "Risky"; elif [[ $replicas -gt 1 && ("$minAvailable" != "100%" || "$maxUnavailable" != "0" || "$maxUnavailable" != "0%") ]]; then printf "%-30s %-30s %-10s\\n" "$type/$name" "$pdbName" "OK"; fi; done; fi; }; echo "Deployments:"; echo "_______"; printf "%-30s %-30s %-10s\\n" "NAME" "PDB" "STATUS"; ${KUBERNETES_DISTRIBUTION_BINARY} --context "$context" --namespace "$namespace" get deployments -o json | jq -c '.items[] | "\\(.metadata.name) \\(.spec.replicas) \\(.spec.selector.matchLabels | to_entries[] | .key + "=" + .value)"' | while read -r line; do check_health "Deployment" $(echo $line | tr -d '"'); done; echo ""; echo "Statefulsets:"; echo "_______"; printf "%-30s %-30s %-10s\\n" "NAME" "PDB" "STATUS"; ${KUBERNETES_DISTRIBUTION_BINARY} --context "$context" --namespace "$namespace" get statefulsets -o json | jq -c '.items[] | "\\(.metadata.name) \\(.spec.replicas) \\(.spec.selector.matchLabels | to_entries[] | .key + "=" + .value)"' | while read -r line; do check_health "StatefulSet" $(echo $line | tr -d '"'); done
    ...    env=${env}
    ...    secret_file__kubeconfig=${KUBECONFIG}
    ...    show_in_rwl_cheatsheet=true
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
            ...    next_steps=Review PodDisruptionBudget for `${risky_pdb}` to ensure it allows pods to be evacuated and rescheduled during maintenance periods.
        END
    END
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add To Report    ${pdb_check.stdout}\n
    RW.Core.Add Pre To Report    Commands Used:\n${history}

Check Resource Quota Utilization in Namepace `${NAMESPACE}`
    [Documentation]    Lists any namespace resource quotas and checks their utilization, raising issues if they are above 80%
    [Tags]    resourcequota    quota    availability    unavailable    policy    ${NAMESPACE}
    ${quota_usage}=    RW.CLI.Run Bash File
    ...    bash_file=resource_quota_check.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    render_in_commandlist=true
    ${recommendations}=    RW.CLI.Run Cli
    ...    cmd=echo '${quota_usage.stdout}' | awk '/Recommended Next Steps:/ {flag=1; next} flag'
    ...    env=${env}
    ...    include_in_history=false
    ${recommendation_list}=    Evaluate    json.loads(r'''${recommendations.stdout}''')    json
    IF    len(@{recommendation_list}) > 0
        FOR    ${item}    IN    @{recommendation_list}
            RW.Core.Add Issue
            ...    severity=${item["severity"]}
            ...    expected=Resource quota should not constrain deployment of resources.
            ...    actual=Resource quota is constrained and might affect deployments.
            ...    title=Resource quota is ${item["usage"]} in namespace `${NAMESPACE}`
            ...    reproduce_hint=kubectl describe resourcequota -n ${NAMESPACE}
            ...    details=${item}
            ...    next_steps=${item["next_step"]}
        END
    END
    RW.Core.Add To Report    ${quota_usage.stdout}\n


*** Keywords ***
Suite Initialization
    ${kubeconfig}=    RW.Core.Import Secret
    ...    kubeconfig
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
    ${ERROR_PATTERN}=    RW.Core.Import User Variable    ERROR_PATTERN
    ...    type=string
    ...    description=The error pattern to use when grep-ing logs.
    ...    pattern=\w*
    ...    example=(Error|Exception)
    ...    default=(Error|Exception)
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
    Set Suite Variable    ${CONTEXT}    ${CONTEXT}
    Set Suite Variable    ${KUBERNETES_DISTRIBUTION_BINARY}    ${KUBERNETES_DISTRIBUTION_BINARY}
    Set Suite Variable    ${NAMESPACE}    ${NAMESPACE}
    Set Suite Variable    ${ERROR_PATTERN}    ${ERROR_PATTERN}
    Set Suite Variable    ${ANOMALY_THRESHOLD}    ${ANOMALY_THRESHOLD}
    Set Suite Variable    ${HOME}    ${HOME}
    Set Suite Variable
    ...    ${env}
    ...    {"KUBECONFIG":"./${kubeconfig.key}", "KUBERNETES_DISTRIBUTION_BINARY":"${KUBERNETES_DISTRIBUTION_BINARY}", "CONTEXT":"${CONTEXT}", "NAMESPACE":"${NAMESPACE}", "HOME":"${HOME}"}
