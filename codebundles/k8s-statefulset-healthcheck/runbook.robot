*** Settings ***
Documentation       Triages issues related to a StatefulSet and its replicas.
Metadata            Author    jon-funk
Metadata            Display Name    Kubernetes StatefulSet Triage
Metadata            Supports    Kubernetes,AKS,EKS,GKE,OpenShift

Library             BuiltIn
Library             String
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             OperatingSystem

Suite Setup         Suite Initialization


*** Tasks ***
Check Readiness Probe Configuration for StatefulSet `${STATEFULSET_NAME}`
    [Documentation]    Validates if a readiness probe has possible misconfigurations
    [Tags]
    ...    readiness
    ...    probe
    ...    workloads
    ...    errors
    ...    failure
    ...    restart
    ...    get
    ...    statefulset
    ...    ${statefulset_name}
    ...    access:read-only
    ${readiness_probe_health}=    RW.CLI.Run Bash File
    ...    bash_file=validate_probes.sh
    ...    cmd_overide=./validate_probes.sh readinessProbe
    ...    env=${env}
    ...    include_in_history=False
    ...    secret_file__kubeconfig=${kubeconfig}
    ${recommendations}=    RW.CLI.Run Cli
    ...    cmd=echo '${readiness_probe_health.stdout}' | awk '/Recommended Next Steps:/ {flag=1; next} flag'
    ...    env=${env}
    ...    include_in_history=false
    IF    len($recommendations.stdout) > 0
        RW.Core.Add Issue
        ...    severity=2
        ...    expected=Readiness probes should be configured and functional for StatefulSet `${STATEFULSET_NAME}` in namespace `${NAMESPACE}`
        ...    actual=Issues found with readiness probe configuration for StatefulSet `${STATEFULSET_NAME}` in namespace `${NAMESPACE}`
        ...    title=Readiness Probe Configuration Issues with StatefulSet `${STATEFULSET_NAME}` in namespace `${NAMESPACE}`
        ...    reproduce_hint=View Commands Used in Report Output
        ...    details=${readiness_probe_health.stdout}
        ...    next_steps=${recommendations.stdout}
    END
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Readiness probe testing results:\n\n${readiness_probe_health.stdout}
    RW.Core.Add Pre To Report    Commands Used: ${history}

Check Liveness Probe Configuration for StatefulSet `${STATEFULSET_NAME}`
    [Documentation]    Validates if a Liveliness probe has possible misconfigurations
    [Tags]
    ...    liveliness
    ...    probe
    ...    workloads
    ...    errors
    ...    failure
    ...    restart
    ...    get
    ...    statefulset
    ...    ${statefulset_name}
    ...    access:read-only
    ${liveness_probe_health}=    RW.CLI.Run Bash File
    ...    bash_file=validate_probes.sh
    ...    cmd_overide=./validate_probes.sh livenessProbe
    ...    env=${env}
    ...    include_in_history=False
    ...    secret_file__kubeconfig=${kubeconfig}
    ${recommendations}=    RW.CLI.Run Cli
    ...    cmd=echo '${liveness_probe_health.stdout}' | awk '/Recommended Next Steps:/ {flag=1; next} flag'
    ...    env=${env}
    ...    include_in_history=false
    IF    len($recommendations.stdout) > 0
        RW.Core.Add Issue
        ...    severity=2
        ...    expected=Liveness probes should be configured and functional for statefulset `${STATEFULSET_NAME}` in namespace `${NAMESPACE}`
        ...    actual=Issues found with liveness probe configuration for StatefulSet `${STATEFULSET_NAME}` in namespace `${NAMESPACE}`
        ...    title=Liveness Probe Configuration Issues with StatefulSet `${STATEFULSET_NAME}` in namespace `${NAMESPACE}`
        ...    reproduce_hint=View Commands Used in Report Output
        ...    details=${liveness_probe_health.stdout}
        ...    next_steps=${recommendations.stdout}
    END
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Liveness probe testing results:\n\n${liveness_probe_health.stdout}
    RW.Core.Add Pre To Report    Commands Used: ${history}

Troubleshoot StatefulSet Warning Events for `${STATEFULSET_NAME}`
    [Documentation]    Fetches warning events related to the statefulset workload in the namespace and triages any issues found in the events.
    [Tags]    access:read-only  events    workloads    errors    warnings    get    statefulset    ${statefulset_name}
    ${events}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get events --context ${CONTEXT} -n ${NAMESPACE} -o json | jq '(now - (60*60)) as $time_limit | [ .items[] | select(.type == "Warning" and (.involvedObject.kind == "StatefulSet" or .involvedObject.kind == "Pod") and (.involvedObject.name | tostring | contains("${STATEFULSET_NAME}")) and (.lastTimestamp | fromdateiso8601) >= $time_limit) | {kind: .involvedObject.kind, name: .involvedObject.name, reason: .reason, message: .message, firstTimestamp: .firstTimestamp, lastTimestamp: .lastTimestamp} ] | group_by([.kind, .name]) | map({kind: .[0].kind, name: .[0].name, count: length, reasons: map(.reason) | unique, messages: map(.message) | unique, firstTimestamp: map(.firstTimestamp | fromdateiso8601) | sort | .[0] | todateiso8601, lastTimestamp: map(.lastTimestamp | fromdateiso8601) | sort | reverse | .[0] | todateiso8601})'
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    show_in_rwl_cheatsheet=true
    ...    render_in_commandlist=true
    ${object_list}=    Evaluate    json.loads(r'''${events.stdout}''')    json
    IF    len(@{object_list}) > 0
        FOR    ${item}    IN    @{object_list}
            ${message_string}=    Catenate    SEPARATOR;    @{item["messages"]}
            ${messages}=    Replace String    ${message_string}    "    ${EMPTY}
            ${item_next_steps}=    RW.CLI.Run Bash File
            ...    bash_file=workload_next_steps.sh
            ...    cmd_overide=./workload_next_steps.sh "${messages}" "StatefulSet" "${STATEFULSET_NAME}"
            ...    env=${env}
            ...    include_in_history=False
            RW.Core.Add Issue
            ...    severity=4
            ...    expected=Warning events should not be present in namespace `${NAMESPACE}` for StatefulSet `${STATEFULSET_NAME}`
            ...    actual=Warning events are found in namespace `${NAMESPACE}` for StatefulSet `${STATEFULSET_NAME}` which indicate potential issues.
            ...    title= StatefulSet `${STATEFULSET_NAME}` generated warning events for ${item["kind"]} `${item["name"]}`.
            ...    reproduce_hint=View Commands Used in Report Output
            ...    details=${item["kind"]} `${item["name"]}` generated the following warning details:\n`${item}`
            ...    next_steps=${item_next_steps.stdout}
        END
    END
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    ${events.stdout}
    RW.Core.Add Pre To Report    Commands Used: ${history}

Check StatefulSet Event Anomalies for `${STATEFULSET_NAME}` in Namespace `${NAMESPACE}`
    [Documentation]    Parses all events in a namespace within a timeframe and checks for unusual activity, raising issues for any found.
    [Tags]    access:read-only  statefulset    events    info    state    anomolies    count    occurences    ${statefulset_name}
    ${recent_anomalies}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get events --context ${CONTEXT} -n ${NAMESPACE} -o json | jq '(now - (60*60)) as $time_limit | [ .items[] | select(.type != "Warning" and (.involvedObject.kind == "StatefulSet" or .involvedObject.kind == "Pod") and (.involvedObject.name | tostring | contains("${STATEFULSET_NAME}"))) | {kind: .involvedObject.kind, count: .count, name: .involvedObject.name, reason: .reason, message: .message, firstTimestamp: .firstTimestamp, lastTimestamp: .lastTimestamp, duration: (if (((.lastTimestamp | fromdateiso8601) - (.firstTimestamp | fromdateiso8601)) == 0) then 1 else (((.lastTimestamp | fromdateiso8601) - (.firstTimestamp | fromdateiso8601))/60) end) } ] | group_by([.kind, .name]) | map({kind: .[0].kind, name: .[0].name, count: (map(.count) | add), reasons: map(.reason) | unique, messages: map(.message) | unique, average_events_per_minute: (if .[0].duration == 1 then 1 else ((map(.count) | add)/.[0].duration ) end),firstTimestamp: map(.firstTimestamp | fromdateiso8601) | sort | .[0] | todateiso8601, lastTimestamp: map(.lastTimestamp | fromdateiso8601) | sort | reverse | .[0] | todateiso8601})'
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    show_in_rwl_cheatsheet=true
    ...    render_in_commandlist=true
    ${anomaly_list}=    Evaluate    json.loads(r'''${recent_anomalies.stdout}''')    json
    IF    len($anomaly_list) > 0
        FOR    ${item}    IN    @{anomaly_list}
            IF    $item["average_events_per_minute"] > ${ANOMALY_THRESHOLD}
                ${messages}=    Replace String    ${item["messages"][0]}    "    ${EMPTY}
                ${item_next_steps}=    RW.CLI.Run Bash File
                ...    bash_file=workload_next_steps.sh
                ...    cmd_overide=./workload_next_steps.sh "${messages}" "StatefulSet" "${STATEFULSET_NAME}"
                ...    env=${env}
                ...    include_in_history=False
                RW.Core.Add Issue
                ...    severity=3
                ...    expected=Deployment `${STATEFULSET_NAME}` in namespace `${NAMESPACE}` has generated an average events per minute above the threshold of ${ANOMALY_THRESHOLD}.
                ...    actual=Deployment `${STATEFULSET_NAME}` in namespace `${NAMESPACE}` should have less than ${ANOMALY_THRESHOLD} events per minute related to a specific object.
                ...    title= ${item["kind"]} `${item["name"]}` has an average of ${item["average_events_per_minute"]} events per minute (above the threshold of ${ANOMALY_THRESHOLD})
                ...    reproduce_hint=View Commands Used in Report Output
                ...    details=${item["kind"]} `${item["name"]}` has ${item["count"]} normal events that should be reviewed:\n`${item}`
                ...    next_steps=${item_next_steps.stdout}
            END
        END
        ${anomalies_report_output}=    Set Variable    ${recent_anomalies.stdout}
    ELSE
        ${anomalies_report_output}=    Set Variable    No anomalies were detected!
    END
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add To Report    Summary Of Anomalies Detected:\n
    RW.Core.Add To Report    ${anomalies_report_output}\n
    RW.Core.Add Pre To Report    Commands Used:\n${history}

Fetch StatefulSet Logs for `${STATEFULSET_NAME}` in Namespace `${NAMESPACE}` and Add to Report
    [Documentation]    Fetches the last 100 lines of logs for the given statefulset in the namespace.
    [Tags]    access:read-only  fetch    log    pod    container    errors    inspect    trace    info    ${STATEFULSET_NAME}    statefulset
    ${logs}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} logs --tail=100 statefulset/${STATEFULSET_NAME} --context ${CONTEXT} -n ${NAMESPACE}
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    show_in_rwl_cheatsheet=true
    ...    render_in_commandlist=true
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    ${logs.stdout}
    RW.Core.Add Pre To Report    Commands Used: ${history}

Get Related StatefulSet `${STATEFULSET_NAME}` Events
    [Documentation]    Fetches events related to the StatefulSet workload in the namespace.
    [Tags]    events    workloads    errors    warnings    get    statefulset
    ${events}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get events --field-selector type=Warning --context ${CONTEXT} -n ${NAMESPACE} | grep -i "${STATEFULSET_NAME}" || true
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    show_in_rwl_cheatsheet=true
    ...    render_in_commandlist=true
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    ${events.stdout}
    RW.Core.Add Pre To Report    Commands Used: ${history}

Fetch Manifest Details for StatefulSet `${STATEFULSET_NAME}` in Namespace `${NAMESPACE}`
    [Documentation]    Fetches the current state of the statefulset manifest for inspection.
    [Tags]    access:read-only  statefulset    details    manifest    info    ${STATEFULSET_NAME}
    ${statefulset}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get statefulset ${LABELS} --context=${CONTEXT} -n ${NAMESPACE} -o yaml
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    show_in_rwl_cheatsheet=true
    ...    render_in_commandlist=true
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    ${statefulset.stdout}
    RW.Core.Add Pre To Report    Commands Used: ${history}

List Unhealthy Replica Counts for StatefulSets in Namespace `${NAMESPACE}`
    [Documentation]    Pulls the replica information for a given StatefulSet and checks if it's highly available
    ...    , if the replica counts are the expected / healthy values, and if not, what they should be.
    [Tags]
    ...    statefulset
    ...    replicas
    ...    desired
    ...    actual
    ...    available
    ...    ready
    ...    unhealthy
    ...    rollout
    ...    stuck
    ...    pods
    ...    ${NAMESPACE}
    ...    access:read-only
    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get statefulset -n ${NAMESPACE} -o json --context ${CONTEXT} | jq -r '.items[] | select(.status.availableReplicas < .status.replicas) | "---\\nStatefulSet Name: " + (.metadata.name|tostring) + "\\nDesired Replicas: " + (.status.replicas|tostring) + "\\nAvailable Replicas: " + (.status.availableReplicas|tostring)'
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    show_in_rwl_cheatsheet=true
    ...    render_in_commandlist=true
    ${statefulset}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get statefulset ${LABELS} --context=${CONTEXT} -n ${NAMESPACE} -o json | jq -r 'if (.items | length) > 0 then .items[0] else {} end'
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ${available_replicas}=    RW.CLI.Parse Cli Json Output
    ...    rsp=${statefulset}
    ...    extract_path_to_var__available_replicas=status.availableReplicas || `0`
    ...    available_replicas__raise_issue_if_lt=1
    ...    set_issue_title=No Available Replicas for Statefulset In Namespace ${NAMESPACE}
    ...    set_issue_details=No ready/available statefulset pods found for the statefulset with labels ${LABELS} in namespace ${NAMESPACE}, check events, namespace events, helm charts or kustomization objects.
    ...    set_issue_next_steps=Troubleshoot Events In Namespace `${NAMESPACE}`\nCheck for Available Helm Chart Updates\nFetch HelmRelease Error Messages\nCheck Readiness and Liveness Probe Status for pods under the `${LABELS}` labels
    ...    assign_stdout_from_var=available_replicas
    ${desired_replicas}=    RW.CLI.Parse Cli Json Output
    ...    rsp=${statefulset}
    ...    extract_path_to_var__desired_replicas=status.replicas || `0`
    ...    desired_replicas__raise_issue_if_lt=1
    ...    set_issue_title=No Desired Replicas For Statefulset In Namespace ${NAMESPACE}
    ...    set_issue_details=No desired replicas for statefulset under labels ${LABELS} in namespace ${NAMESPACE}
    ...    set_issue_next_steps=Troubleshoot Events In Namespace `${NAMESPACE}`\nCheck Recent Scaling Changes\nCheck for Available Helm Chart Updates\nFetch HelmRelease Error Messages\nCheck Readiness and Liveness Probe Status for pods under the `${LABELS}` labels
    ...    assign_stdout_from_var=desired_replicas
    ${desired_replicas}=    Convert To Number    ${desired_replicas.stdout}
    ${available_replicas}=    Convert To Number    ${available_replicas.stdout}
    RW.Core.Add Pre To Report    StatefulSet State:\n${StatefulSet}
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Commands Used: ${history}


*** Keywords ***
Suite Initialization
    ${kubeconfig}=    RW.Core.Import Secret
    ...    kubeconfig
    ...    type=string
    ...    description=The kubernetes kubeconfig yaml containing connection configuration used to connect to cluster(s).
    ...    pattern=\w*
    ...    example=For examples, start here https://kubernetes.io/docs/concepts/configuration/organize-cluster-access-kubeconfig/
    ${STATEFULSET_NAME}=    RW.Core.Import User Variable    STATEFULSET_NAME
    ...    type=string
    ...    description=Used to target the resource for queries and filtering events.
    ...    pattern=\w*
    ...    example=my-database
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
    ${LABELS}=    RW.Core.Import User Variable    LABELS
    ...    type=string
    ...    description=The Kubernetes labels used to fetch the first matching statefulset.
    ...    pattern=\w*
    ...    example=Could not render example.
    ...    default=
    ${KUBERNETES_DISTRIBUTION_BINARY}=    RW.Core.Import User Variable    KUBERNETES_DISTRIBUTION_BINARY
    ...    type=string
    ...    description=Which binary to use for CLI commands
    ...    enum=[kubectl,oc]
    ...    example=kubectl
    ...    default=kubectl
    ${ANOMALY_THRESHOLD}=    RW.Core.Import User Variable
    ...    ANOMALY_THRESHOLD
    ...    type=string
    ...    description=The rate of occurence per minute at which an Event becomes classified as an anomaly, even if Kubernetes considers it informational.
    ...    pattern=\d+(\.\d+)?
    ...    example=5.0
    ...    default=5.0
    Set Suite Variable    ${kubeconfig}    ${kubeconfig}
    Set Suite Variable    ${CONTEXT}    ${CONTEXT}
    Set Suite Variable    ${ANOMALY_THRESHOLD}    ${ANOMALY_THRESHOLD}
    Set Suite Variable    ${KUBERNETES_DISTRIBUTION_BINARY}    ${KUBERNETES_DISTRIBUTION_BINARY}
    Set Suite Variable    ${NAMESPACE}    ${NAMESPACE}
    Set Suite Variable    ${STATEFULSET_NAME}    ${STATEFULSET_NAME}
    Set Suite Variable
    ...    ${env}
    ...    {"KUBECONFIG":"./${kubeconfig.key}", "KUBERNETES_DISTRIBUTION_BINARY":"${KUBERNETES_DISTRIBUTION_BINARY}", "CONTEXT":"${CONTEXT}", "NAMESPACE":"${NAMESPACE}", "ANOMALY_THRESHOLD":"${ANOMALY_THRESHOLD}", "STATEFULSET_NAME": "${STATEFULSET_NAME}"}

    IF    "${LABELS}" != ""
        ${LABELS}=    Set Variable    -l ${LABELS}
    END
    Set Suite Variable    ${LABELS}    ${LABELS}
