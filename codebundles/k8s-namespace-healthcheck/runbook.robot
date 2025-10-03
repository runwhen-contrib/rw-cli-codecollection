*** Settings ***
Documentation       This taskset runs general troubleshooting checks against all applicable objects in a namespace. Looks for warning events, odd or frequent normal events, restarting containers and failed or pending pods.
Metadata            Author    stewartshea
Metadata            Display Name    Kubernetes Namespace Inspection
Metadata            Supports    Kubernetes,AKS,EKS,GKE,OpenShift

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.K8sHelper
Library             RW.NextSteps
Library             RW.platform
Library             OperatingSystem
Library             DateTime
Library             Collections
Library             String

Suite Setup         Suite Initialization


*** Tasks ***
Inspect Warning Events in Namespace `${NAMESPACE}`
    [Documentation]    Queries all warning events in a given namespace within the user specified age,
    ...    fetches the list of involved pod names, groups the events, collects event message details
    ...    and searches for a useful next step based on these details.
    [Tags]    access:read-only    namespace    trace    error    pods    events    logs    grep    ${NAMESPACE}
    ${warning_events_by_object}=    RW.CLI.Run Bash File
    ...    bash_file=warning_events.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    show_in_rwl_cheatsheet=true
    ...    render_in_commandlist=true
    ...    include_in_history=False
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
            ${item_owner}=    RW.CLI.Run Bash File
            ...    bash_file=find_resource_owners.sh
            ...    cmd_override=./find_resource_owners.sh ${object_kind.stdout} ${object_short_name.stdout} ${NAMESPACE} ${CONTEXT}
            ...    env=${env}
            ...    secret_file__kubeconfig=${kubeconfig}
            ...    include_in_history=False
            ${messages}=    RW.K8sHelper.Sanitize Messages    ${item["summary_messages"]}
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
            # Drop anything that is unknown / unknown 
            # Usually this resource no longer exists.
            # FIXME: Consider a deeper insight into an object that no longer exists but the event still does
            IF    $owner_name != "Unknown"
                # Get current health status for the workload to provide context
                ${workload_health}=    Set Variable    **Current Status:** Unable to retrieve
                IF    "${owner_kind}" == "Deployment"
                    ${health_check}=    RW.CLI.Run Cli
                    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get deployment/${owner_name} --context ${CONTEXT} -n ${NAMESPACE} -o json | jq '{desired_replicas: .spec.replicas, ready_replicas: (.status.readyReplicas // 0), available_replicas: (.status.availableReplicas // 0), conditions: [.status.conditions[]? | select(.type == "Available") | {status: .status, reason: .reason}]}'
                    ...    env=${env}
                    ...    secret_file__kubeconfig=${kubeconfig}
                    ...    include_in_history=false
                    
                    IF    ${health_check.returncode} == 0 and '''${health_check.stdout}''' != ''
                        TRY
                            ${health_data}=    Evaluate    json.loads(r'''${health_check.stdout}''') if r'''${health_check.stdout}'''.strip() else {}    json
                            ${desired}=    Evaluate    $health_data.get('desired_replicas', 0)
                            ${ready}=    Evaluate    $health_data.get('ready_replicas', 0)
                            ${available}=    Evaluate    $health_data.get('available_replicas', 0)
                            ${conditions}=    Evaluate    $health_data.get('conditions', [])
                            
                            ${workload_health}=    Set Variable    **Current Deployment Status:** ${ready}/${desired} ready replicas, ${available} available
                            FOR    ${condition}    IN    @{conditions}
                                ${cond_status}=    Evaluate    $condition.get('status', 'Unknown')
                                ${cond_reason}=    Evaluate    $condition.get('reason', '')
                                ${workload_health}=    Catenate    ${workload_health}    \n**Available:** ${cond_status} (${cond_reason})
                            END
                        EXCEPT
                            Log    Warning: Failed to parse deployment health status for ${owner_name}
                        END
                    END
                ELSE IF    "${owner_kind}" == "Pod"
                    ${health_check}=    RW.CLI.Run Cli
                    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get pod/${owner_name} --context ${CONTEXT} -n ${NAMESPACE} -o json | jq '{phase: .status.phase, ready: (.status.conditions[]? | select(.type == "Ready") | .status), restart_count: (.status.containerStatuses[]? | .restartCount) | add}'
                    ...    env=${env}
                    ...    secret_file__kubeconfig=${kubeconfig}
                    ...    include_in_history=false
                    
                    IF    ${health_check.returncode} == 0 and '''${health_check.stdout}''' != ''
                        TRY
                            ${health_data}=    Evaluate    json.loads(r'''${health_check.stdout}''') if r'''${health_check.stdout}'''.strip() else {}    json
                            ${phase}=    Evaluate    $health_data.get('phase', 'Unknown')
                            ${ready}=    Evaluate    $health_data.get('ready', 'Unknown')
                            ${restarts}=    Evaluate    $health_data.get('restart_count', 0)
                            ${workload_health}=    Set Variable    **Current Pod Status:** Phase=${phase}, Ready=${ready}, Restarts=${restarts}
                        EXCEPT
                            Log    Warning: Failed to parse pod health status for ${owner_name}
                        END
                    END
                END
                
                ${issues}=    RW.CLI.Run Bash File
                ...    bash_file=workload_issues.sh
                ...    cmd_override=./workload_issues.sh "${messages}" "${owner_kind}" "${owner_name}"
                ...    env=${env}
                ...    include_in_history=False
                ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
                FOR    ${issue}    IN    @{issue_list}
                    # Improve issue descriptions to distinguish between different types of problems
                    ${is_pod_issue}=    Evaluate    "${owner_kind}" == "Pod"
                    IF    ${is_pod_issue}
                        ${actual_description}=    Set Variable    Pod-level issues detected for `${owner_name}` in namespace `${NAMESPACE}` - check if other pods in the workload are healthy
                    ELSE
                        ${actual_description}=    Set Variable    Warning events found for ${owner_kind} `${owner_name}` in namespace `${NAMESPACE}` which indicate potential issues
                    END
                    
                    # Adjust severity based on current workload health for deployments
                    ${adjusted_severity}=    Set Variable    ${issue["severity"]}
                    IF    "${owner_kind}" == "Deployment" and '''${workload_health}''' != '''**Current Status:** Unable to retrieve'''
                        # Check if deployment is healthy (has ready replicas and is available)
                        ${has_zero_ready}=    Evaluate    __import__('re').search(r'\b0/\d+\s+ready replicas', '''${workload_health}''') is not None    modules=re
                        ${is_healthy}=    Evaluate    "ready replicas" in '''${workload_health}''' and "True" in '''${workload_health}''' and not ${has_zero_ready}
                        
                        # Lower severity for probe failures when deployment is healthy
                        ${is_probe_issue}=    Evaluate    "probe failures" in '''${issue["title"]}'''.lower()
                        IF    ${is_healthy} and ${is_probe_issue}
                            ${adjusted_severity}=    Set Variable    4
                            Log    Lowering severity to 4 for probe failures in healthy deployment ${owner_name}
                        END
                    END
                    
                    ${issue_timestamp}=    RW.Core.Get Issue Timestamp

                    
                    RW.Core.Add Issue
                    ...    severity=${adjusted_severity}
                    ...    expected=Warning events should not be present in namespace `${NAMESPACE}` for ${owner_kind} `${owner_name}`
                    ...    actual=${actual_description}
                    ...    title= ${issue["title"]}
                    ...    reproduce_hint=kubectl get events --field-selector type=Warning --context ${CONTEXT} -n ${NAMESPACE}
                    ...    details=${workload_health}\n\n${issue["details"]}
                    ...    next_steps=${issue["next_steps"]}
                    ...    observed_at=${issue_timestamp}
                END
            END
        END
    END
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    **Summary of Warning Events in Namespace: ${NAMESPACE}**\n\n${warning_events_by_object.stdout}
    RW.Core.Add Pre To Report    **Commands Used:**\n${history}


Inspect Container Restarts In Namespace `${NAMESPACE}`
    [Documentation]    Fetches pods that have container restarts and provides a report of the restart issues.
    [Tags]     access:read-only    namespace    containers    status    restarts    ${namespace}
    ${container_restart_details}=    RW.CLI.Run Cli
    ...    cmd=TIME_PERIOD="${CONTAINER_RESTART_AGE}"; TIME_PERIOD_UNIT=$(echo $TIME_PERIOD | awk '{print substr($0,length($0),1)}'); TIME_PERIOD_VALUE=$(echo $TIME_PERIOD | awk '{print substr($0,1,length($0)-1)}'); if [[ $TIME_PERIOD_UNIT == "m" ]]; then DATE_CMD_ARG="$TIME_PERIOD_VALUE minutes ago"; elif [[ $TIME_PERIOD_UNIT == "h" ]]; then DATE_CMD_ARG="$TIME_PERIOD_VALUE hours ago"; else echo "Unsupported time period unit. Use 'm' for minutes or 'h' for hours."; exit 1; fi; THRESHOLD_TIME=$(date -u --date="$DATE_CMD_ARG" +"%Y-%m-%dT%H:%M:%SZ"); $KUBERNETES_DISTRIBUTION_BINARY get pods --context=$CONTEXT -n $NAMESPACE -o json | jq -r --argjson exit_code_explanations '{"0": "Success", "1": "Error", "2": "Misconfiguration", "130": "Pod terminated by SIGINT", "134": "Abnormal Termination SIGABRT", "137": "Pod terminated by SIGKILL - Possible OOM", "143":"Graceful Termination SIGTERM"}' --arg threshold_time "$THRESHOLD_TIME" '.items[] | select(.status.containerStatuses != null) | select(any(.status.containerStatuses[]; .restartCount > 0 and (.lastState.terminated.finishedAt // "1970-01-01T00:00:00Z") > $threshold_time)) | "---\\npod_name: \\(.metadata.name)\\n" + (.status.containerStatuses[] | "containers: \\(.name)\\nrestart_count: \\(.restartCount)\\nmessage: \\(.state.waiting.message // "N/A")\\nterminated_reason: \\(.lastState.terminated.reason // "N/A")\\nterminated_finishedAt: \\(.lastState.terminated.finishedAt // "N/A")\\nterminated_exitCode: \\(.lastState.terminated.exitCode // "N/A")\\nexit_code_explanation: \\($exit_code_explanations[.lastState.terminated.exitCode | tostring] // "Unknown exit code")") + "\\n---\\n"'
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    show_in_rwl_cheatsheet=true
    ...    render_in_commandlist=true
    ${container_restart_analysis}=    RW.CLI.Run Bash File
    ...    bash_file=container_restarts.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    include_in_history=False
    ${recommendations}=    RW.CLI.Run Cli
    ...    cmd=cat container_restart_issues.json
    ...    env=${env}
    ...    include_in_history=false
    IF    $recommendations.stdout != ""
        ${recommendation_list}=    Evaluate    json.loads(r'''${recommendations.stdout}''')    json
        IF    len(@{recommendation_list}) > 0
            FOR    ${item}    IN    @{recommendation_list}
                ${issue_timestamp}=    RW.Core.Get Issue Timestamp

                RW.Core.Add Issue
                ...    severity=${item["severity"]}
                ...    expected=Containers should not be restarting in namespace `${NAMESPACE}`
                ...    actual=We found containers with restarts in namespace `${NAMESPACE}`
                ...    title=${item["title"]}
                ...    reproduce_hint=${container_restart_details.cmd}
                ...    details=${item["details"]}
                ...    next_steps=${item["next_steps"]}
                ...    observed_at=${issue_timestamp}
            END
        END
    END
    ${history}=    RW.CLI.Pop Shell History
    IF    """${container_restart_details.stdout}""" == ""
        ${container_restart_details}=    Set Variable    No container restarts found
    ELSE
        ${container_restart_details}=    Set Variable    ${container_restart_details.stdout}
    END
    RW.Core.Add Pre To Report    **Summary of Container Restarts in Namespace: ${NAMESPACE}**\n\n${container_restart_analysis.stdout}
    RW.Core.Add Pre To Report    **Commands Used:**\n${history}


Inspect Pending Pods In Namespace `${NAMESPACE}`
    [Documentation]    Fetches pods that are pending and provides details.
    [Tags]     access:read-only    namespace    pods    status    pending    ${NAMESPACE}
    ${pending_pods}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get pods --context=${CONTEXT} -n ${NAMESPACE} --field-selector=status.phase=Pending --no-headers -o json | jq -r '[.items[] | {pod_name: .metadata.name, status: (.status.phase // "N/A"), message: (.status.conditions[0].message // "N/A"), reason: (.status.conditions[0].reason // "N/A"), containerStatus: (.status.containerStatuses[0].state // "N/A"), containerMessage: (.status.containerStatuses[0].state.waiting?.message // "N/A"), containerReason: (.status.containerStatuses[0].state.waiting?.reason // "N/A")}]'
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    show_in_rwl_cheatsheet=true
    ...    render_in_commandlist=true
    ${pending_pod_list}=    Evaluate    json.loads(r'''${pending_pods.stdout}''')    json
    IF    len($pending_pod_list) > 0
        FOR    ${item}    IN    @{pending_pod_list}
            ${item_owner}=    RW.CLI.Run Bash File
            ...    bash_file=find_resource_owners.sh
            ...    cmd_override=./find_resource_owners.sh Pod ${item["pod_name"]} ${NAMESPACE} ${CONTEXT}
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
            ${message_string}=    Evaluate
            ...    "${item.get('message', '')};${item.get('containerMessage', '')};${item.get('containerReason', '')}"
            ${messages}=    RW.K8sHelper.Sanitize Messages    ${message_string}
            ${issues}=    RW.CLI.Run Bash File
            ...    bash_file=workload_issues.sh
            ...    cmd_override=./workload_issues.sh "${messages}" "${owner_kind}" "${owner_name}"
            ...    env=${env}
            ...    include_in_history=False
            ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
            FOR    ${issue}    IN    @{issue_list}
                ${issue_timestamp}=    RW.Core.Get Issue Timestamp

                RW.Core.Add Issue
                ...    severity=${issue["severity"]}
                ...    expected=Pods should not be pending in `${NAMESPACE}`.
                ...    actual=Pod `${item["pod_name"]}` is pending with ${item["containerReason"]}
                ...    title= ${issue["title"]}
                ...    reproduce_hint=${pending_pods.cmd}
                ...    details=${issue["details"]}
                ...    next_steps=${issue["next_steps"]}
                ...    observed_at=${issue_timestamp}
            END
        END
    END
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    **Summary of Pending Pods in Namespace: ${NAMESPACE}**\n\n${pending_pods.stdout}
    RW.Core.Add Pre To Report    **Commands Used:**\n${history}


Inspect Failed Pods In Namespace `${NAMESPACE}`
    [Documentation]    Fetches all pods which are not running (unready) in the namespace and adds them to a report for future review.
    [Tags]     access:read-only    namespace    pods    status    unready    not starting    phase    failed    ${namespace}
    ${unreadypods_details}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get pods --context=${CONTEXT} -n ${NAMESPACE} --field-selector=status.phase=Failed --no-headers -o json | jq -r --argjson exit_code_explanations '{"0": "Success", "1": "Error", "2": "Misconfiguration", "130": "Pod terminated by SIGINT", "134": "Abnormal Termination SIGABRT", "137": "Pod terminated by SIGKILL - Possible OOM", "143":"Graceful Termination SIGTERM"}' '[.items[] | {pod_name: .metadata.name, restart_count: (.status.containerStatuses[0].restartCount // "N/A"), message: (.status.message // "N/A"), terminated_finishedAt: (.status.containerStatuses[0].state.terminated.finishedAt // "N/A"), exit_code: (.status.containerStatuses[0].state.terminated.exitCode // "N/A"), exit_code_explanation: ($exit_code_explanations[.status.containerStatuses[0].state.terminated.exitCode | tostring] // "Unknown exit code")}]'
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    show_in_rwl_cheatsheet=true
    ...    render_in_commandlist=true
    ${unready_pods_list}=    Evaluate    json.loads(r'''${unreadypods_details.stdout}''')    json
    IF    len($unready_pods_list) > 0
        FOR    ${item}    IN    @{unready_pods_list}
            ${item_owner}=    RW.CLI.Run Bash File
            ...    bash_file=find_resource_owners.sh
            ...    cmd_override=./find_resource_owners.sh Pod ${item["pod_name"]} ${NAMESPACE} ${CONTEXT}
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
            ${message_string}=    Evaluate    "${item.get('message', '')};${item.get('containerMessage', '')}"
            ${messages}=    RW.K8sHelper.Sanitize Messages    ${message_string}
            ${issues}=    RW.CLI.Run Bash File
            ...    bash_file=workload_issues.sh
            ...    cmd_override=./workload_issues.sh "${messages}" "${owner_kind}" "${owner_name}"
            ...    env=${env}
            ...    include_in_history=False
            ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
            FOR    ${issue}    IN    @{issue_list}
                ${issue_timestamp}=    RW.Core.Get Issue Timestamp

                RW.Core.Add Issue
                ...    severity=${issue["severity"]}
                ...    expected=No pods should be in an unready state in namespace `${NAMESPACE}`.
                ...    actual=Pod `${item["pod_name"]}` in `${NAMESPACE}` is NotReady or Failed.
                ...    title= ${issue["title"]}
                ...    reproduce_hint=${unreadypods_details.cmd}
                ...    details=${issue["details"]}
                ...    next_steps=${issue["next_steps"]}
                ...    observed_at=${issue_timestamp}
            END
        END
    END
    ${history}=    RW.CLI.Pop Shell History
    IF    """${unreadypods_details.stdout}""" == ""
        ${unreadypods_details}=    Set Variable    No unready pods found
    ELSE
        ${unreadypods_details}=    Set Variable    ${unreadypods_details.stdout}
    END
    RW.Core.Add Pre To Report    **Summary of Unready Pods in Namespace: ${NAMESPACE}**\n\n${unreadypods_details}
    RW.Core.Add Pre To Report    **Commands Used:**\n${history}


Inspect Workload Status Conditions In Namespace `${NAMESPACE}`
    [Documentation]    Parses all workloads in a namespace and inspects their status conditions for issues. Status conditions with a status value of False are considered an error.
    [Tags]     access:read-only    namespace    status    conditions    pods    reasons    workloads    ${namespace}
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
                Exit For Loop
            END
            ${item_next_steps}=    RW.CLI.Run Bash File
            ...    bash_file=workload_next_steps.sh
            ...    cmd_override=./workload_next_steps.sh "${item["conditions"]}" "${owner_kind}" "${owner_name}"
            ...    env=${env}
            ...    secret_file__kubeconfig=${kubeconfig}
            ...    include_in_history=False
            ${issue_timestamp}=    RW.Core.Get Issue Timestamp

            RW.Core.Add Issue
            ...    severity=4
            ...    expected=Objects should post a status of True in `${NAMESPACE}`
            ...    actual=Objects in `${NAMESPACE}` were found with a status of False - indicating one or more unhealthy components.
            ...    title= ${object_kind.stdout} `${object_name.stdout}` has posted a status of: ${object_status.stdout}
            ...    reproduce_hint=View Commands Used in Report Output
            ...    details=${object_kind.stdout} `${object_name.stdout}` is owned by ${owner_kind} `${owner_name}` and has indicated an unhealthy status.\n${item}
            ...    next_steps=${item_next_steps.stdout}
            ...    observed_at=${issue_timestamp}
        END
    END
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    **Summary of Pods with Failing Conditions in Namespace `${NAMESPACE}`**\n\n${workload_info.stdout}
    RW.Core.Add Pre To Report    **Commands Used:**\n${history}


Get Listing Of Resources In Namespace `${NAMESPACE}`
    [Documentation]    Simple fetch all to provide a snapshot of information about the workloads in the namespace for future review in a report.
    [Tags]     access:read-only    get all    resources    info    workloads    namespace    manifests    ${namespace}
    ${all_results}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} api-resources --verbs=list --namespaced -o name --context=${CONTEXT} | xargs -n 1 bash -c '${KUBERNETES_DISTRIBUTION_BINARY} get $0 --show-kind --ignore-not-found -n ${NAMESPACE} --context=${CONTEXT}'
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    show_in_rwl_cheatsheet=true
    ...    render_in_commandlist=true
    ...    timeout_seconds=180
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    **Informational Get All for Namespace: ${NAMESPACE}**\n\n${all_results.stdout}
    RW.Core.Add Pre To Report    **Commands Used:**\n${history}


Check Event Anomalies in Namespace `${NAMESPACE}`
    [Documentation]    Fetches non warning events in a namespace within a timeframe and checks for unusual activity, raising issues for any found.
    [Tags]     access:read-only    namespace    events    info    state    anomolies    count    occurences    ${namespace}
    ${recent_events_by_object}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get events --field-selector type!=Warning --context ${CONTEXT} -n ${NAMESPACE} -o json > events.json && cat events.json | jq -r '[.items[] | select(.involvedObject.name != null and .involvedObject.name != "" and .involvedObject.name != "Unknown" and .involvedObject.kind != null and .involvedObject.kind != "") | {namespace: .involvedObject.namespace, kind: .involvedObject.kind, name: ((if .involvedObject and .involvedObject.kind == "Pod" then (.involvedObject.name | split("-")[:-1] | join("-")) else .involvedObject.name end) // ""), count: .count, firstTimestamp: .firstTimestamp, lastTimestamp: .lastTimestamp, reason: .reason, message: .message}] | group_by(.namespace, .kind, .name) | .[] | {(.[0].namespace + "/" + .[0].kind + "/" + .[0].name): {events: .}}' | jq -r --argjson threshold "${ANOMALY_THRESHOLD}" 'to_entries[] | {object: .key, oldest_timestamp: ([.value.events[] | .firstTimestamp] | min), most_recent_timestamp: ([.value.events[] | .lastTimestamp] | max), events_per_minute: (reduce .value.events[] as $event (0; . + $event.count) / (((([.value.events[] | .lastTimestamp | fromdateiso8601] | max) - ([.value.events[] | .firstTimestamp | fromdateiso8601] | min)) / 60) | if . < 1 then 1 else . end)), total_events: (reduce .value.events[] as $event (0; . + $event.count)), summary_messages: [.value.events[] | .message] | unique | join("; ")} | select(.events_per_minute > $threshold)' | jq -s '.'
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
            ${messages}=    RW.K8sHelper.Sanitize Messages    ${item["summary_messages"]}
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
            ${issues}=    RW.CLI.Run Bash File
            ...    bash_file=workload_issues.sh
            ...    cmd_override=./workload_issues.sh "${messages}" "${owner_kind}" "${owner_name}"
            ...    env=${env}
            ...    secret_file__kubeconfig=${kubeconfig}
            ...    include_in_history=False
            ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
            FOR    ${issue}    IN    @{issue_list}
                ${issue_timestamp}=    RW.Core.Get Issue Timestamp

                RW.Core.Add Issue
                ...    severity=${issue["severity"]}
                ...    expected=Normal events should not frequently repeat in `${NAMESPACE}`
                ...    actual=Frequently events may be repeating in `${NAMESPACE}` which could indicate potential issues.
                ...    title= ${issue["title"]}
                ...    reproduce_hint=${recent_events_by_object.cmd}
                ...    details=${issue["details"]}
                ...    next_steps=${issue["next_steps"]}
                ...    observed_at=${issue_timestamp}
            END
        END
    END

    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    **Summary of Event Anomalies Detected in Namespace `${NAMESPACE}`**\n\n${recent_events_by_object.stdout}
    RW.Core.Add Pre To Report    **Commands Used:**\n${history}


Check Missing or Risky PodDisruptionBudget Policies in Namepace `${NAMESPACE}`
    [Documentation]    Searches through deployemnts and statefulsets to determine if PodDistruptionBudgets are missing and/or are configured in a risky way that might affect maintenance activities.
    [Tags]
    ...    access:read-only    
    ...    poddisruptionbudget
    ...    pdb
    ...    maintenance
    ...    availability
    ...    unavailable
    ...    risky
    ...    missing
    ...    policy
    ...    ${namespace}
    ${pdb_check}=    RW.CLI.Run Cli
    ...    cmd=context="${CONTEXT}"; namespace="${NAMESPACE}"; check_health() { local type=$1; local name=$2; local replicas=$3; local selector=$4; local pdbs=$(${KUBERNETES_DISTRIBUTION_BINARY} --context "$context" --namespace "$namespace" get pdb -o json | jq -c --arg selector "$selector" '.items[] | select(.spec.selector.matchLabels | to_entries[] | .key + "=" + .value == $selector)'); if [[ $replicas -gt 1 && -z "$pdbs" ]]; then printf "%-30s %-30s %-10s\\n" "$type/$name" "" "Missing"; else echo "$pdbs" | jq -c . | while IFS= read -r pdb; do local pdbName=$(echo "$pdb" | jq -r '.metadata.name'); local minAvailable=$(echo "$pdb" | jq -r '.spec.minAvailable // ""'); local maxUnavailable=$(echo "$pdb" | jq -r '.spec.maxUnavailable // ""'); if [[ "$minAvailable" == "100%" || "$maxUnavailable" == "0" || "$maxUnavailable" == "0%" ]]; then printf "%-30s %-30s %-10s\\n" "$type/$name" "$pdbName" "Risky"; elif [[ $replicas -gt 1 && ("$minAvailable" != "100%" || "$maxUnavailable" != "0" || "$maxUnavailable" != "0%") ]]; then printf "%-30s %-30s %-10s\\n" "$type/$name" "$pdbName" "OK"; fi; done; fi; }; echo "Deployments:"; echo "_______"; printf "%-30s %-30s %-10s\\n" "NAME" "PDB" "STATUS"; ${KUBERNETES_DISTRIBUTION_BINARY} --context "$context" --namespace "$namespace" get deployments -o json | jq -c '.items[] | "\\(.metadata.name) \\(.spec.replicas) \\(.spec.selector.matchLabels | to_entries[] | .key + "=" + .value)"' | while read -r line; do check_health "Deployment" $(echo $line | tr -d '"'); done; echo ""; echo "Statefulsets:"; echo "_______"; printf "%-30s %-30s %-10s\\n" "NAME" "PDB" "STATUS"; ${KUBERNETES_DISTRIBUTION_BINARY} --context "$context" --namespace "$namespace" get statefulsets -o json | jq -c '.items[] | "\\(.metadata.name) \\(.spec.replicas) \\(.spec.selector.matchLabels | to_entries[] | .key + "=" + .value)"' | while read -r line; do check_health "StatefulSet" $(echo $line | tr -d '"'); done
    ...    env=${env}
    ...    secret_file__kubeconfig=${KUBECONFIG}
    ...    show_in_rwl_cheatsheet=true
    ...    render_in_commandlist=true
    ${risky_pdbs}=    RW.CLI.Run Cli
    ...    cmd=echo "${pdb_check.stdout}" | grep 'Risky' | cut -f 1 -d ' ' | sed 's/^ *//; s/ *$//' | awk -F'/' '{ gsub(/^ *| *$/, "", $1); gsub(/^ *| *$/, "", $2); print $1 "/" $2 }' | sed 's/ *$//' 
    ...    include_in_history=False
    ${missing_pdbs}=    RW.CLI.Run Cli
    ...    cmd=echo "${pdb_check.stdout}" | grep 'Missing' | cut -f 1 -d ' ' | sed 's/^ *//; s/ *$//' | awk -F'/' '{ gsub(/^ *| *$/, "", $1); gsub(/^ *| *$/, "", $2); print $1 "/" $2 }' | sed 's/ *$//' 
    ...    include_in_history=False
    # Raise Issues on Missing PDBS
    IF    len($missing_pdbs.stdout) > 0
        @{missing_pdb_list}=    Split To Lines    ${missing_pdbs.stdout}
        FOR    ${missing_pdb}    IN    @{missing_pdb_list}
            ${issue_timestamp}=    RW.Core.Get Issue Timestamp

            RW.Core.Add Issue
            ...    severity=4
            ...    expected=PodDisruptionBudgets in namespace `${NAMESPACE}` should exist for applications that have more than 1 replica
            ...    actual=We detected Deployments or StatefulSets in namespace `${NAMESPACE}` which are missing PodDisruptionBudgets
            ...    title=PodDisruptionBudget missing for `${missing_pdb}` in namespace `${NAMESPACE}`
            ...    reproduce_hint=View Commands Used in Report Output
            ...    details=${pdb_check.stdout}
            ...    next_steps=Create missing [PodDisruptionBudget](https://kubernetes.io/docs/concepts/workloads/pods/disruptions/#pod-disruption-budgets) for `${missing_pdb}`
            ...    observed_at=${issue_timestamp}
        END
    END
    # Raise issues on Risky PDBS
    IF    len($risky_pdbs.stdout) > 0
        @{risky_pdb_list}=    Split To Lines    ${risky_pdbs.stdout}
        FOR    ${risky_pdb}    IN    @{risky_pdb_list}
            ${issue_timestamp}=    RW.Core.Get Issue Timestamp

            RW.Core.Add Issue
            ...    severity=4
            ...    expected=PodDisruptionBudgets in `${NAMESPACE}` should not block regular maintenance
            ...    actual=PodDisruptionBudgets in namespace `${NAMESPACE}` are considered Risky to maintenance operations.
            ...    title=PodDisruptionBudget configured for `${risky_pdb}` in namespace `${NAMESPACE}` could be a risk.
            ...    reproduce_hint=View Commands Used in Report Output
            ...    details=${pdb_check.stdout}
            ...    next_steps=Review [PodDisruptionBudget](https://kubernetes.io/docs/concepts/workloads/pods/disruptions/#pod-disruption-budgets) for `${risky_pdb}` to ensure it allows pods to be evacuated and rescheduled during maintenance periods.
            ...    observed_at=${issue_timestamp}
        END
    END
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    **PodDisruptionBudget Analysis for Namespace `${NAMESPACE}`**\n\n${pdb_check.stdout}
    RW.Core.Add Pre To Report    **Commands Used:**\n${history}


Check Resource Quota Utilization in Namespace `${NAMESPACE}`
    [Documentation]    Lists any namespace resource quotas and checks their utilization, raising issues if they are above 80%
    [Tags]     access:read-only    resourcequota    quota    availability    unavailable    policy    ${namespace}
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
    IF    $recommendations.stdout != ""
        ${recommendation_list}=    Evaluate    json.loads(r'''${recommendations.stdout}''')    json
        IF    len(@{recommendation_list}) > 0
            FOR    ${item}    IN    @{recommendation_list}
                ${issue_timestamp}=    RW.Core.Get Issue Timestamp

                RW.Core.Add Issue
                ...    severity=${item["severity"]}
                ...    expected=Resource quota should not constrain deployment of resources.
                ...    actual=Resource quota is constrained and might affect deployments.
                ...    title=Resource quota is ${item["usage"]} in namespace `${NAMESPACE}`
                ...    reproduce_hint=kubectl describe resourcequota -n ${NAMESPACE}
                ...    details=${item}
                ...    next_steps=${item["next_step"]}
                ...    observed_at=${issue_timestamp}
            END
        END
    END
    RW.Core.Add Pre To Report    **Resource Quota Utilization Analysis for Namespace `${NAMESPACE}`**\n\n${quota_usage.stdout}
    
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    **Commands Used:**\n${history}


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
    ${EVENT_AGE}=    RW.Core.Import User Variable    EVENT_AGE
    ...    type=string
    ...    description=The time window in minutes as to when the event was last seen.
    ...    pattern=((\d+?)m)?
    ...    example=30m
    ...    default=30m
    ${CONTAINER_RESTART_AGE}=    RW.Core.Import User Variable    CONTAINER_RESTART_AGE
    ...    type=string
    ...    description=The time window (in (h) hours or (m) minutes) as search for container restarts.
    ...    pattern=((\d+?)m)?
    ...    example=4h
    ...    default=4h
    Set Suite Variable    ${kubeconfig}    ${kubeconfig}
    Set Suite Variable    ${CONTEXT}    ${CONTEXT}
    Set Suite Variable    ${KUBERNETES_DISTRIBUTION_BINARY}    ${KUBERNETES_DISTRIBUTION_BINARY}
    Set Suite Variable    ${NAMESPACE}    ${NAMESPACE}
    Set Suite Variable    ${EVENT_AGE}    ${EVENT_AGE}
    Set Suite Variable    ${ANOMALY_THRESHOLD}    ${ANOMALY_THRESHOLD}
    Set Suite Variable    ${CONTAINER_RESTART_AGE}    ${CONTAINER_RESTART_AGE}
    Set Suite Variable
    ...    ${env}
                    ...    observed_at=${issue_timestamp}
    ...    {"KUBECONFIG":"./${kubeconfig.key}", "KUBERNETES_DISTRIBUTION_BINARY":"${KUBERNETES_DISTRIBUTION_BINARY}", "CONTEXT":"${CONTEXT}", "NAMESPACE":"${NAMESPACE}", "CONTAINER_RESTART_AGE": "${CONTAINER_RESTART_AGE}", "EVENT_AGE": "${EVENT_AGE}"}
