*** Settings ***
Documentation       Triages issues related to a deployment and its replicas.
Metadata            Author    stewartshea
Metadata            Display Name    Kubernetes Deployment Triage
Metadata            Supports    Kubernetes,AKS,EKS,GKE,OpenShift

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             RW.NextSteps
Library             OperatingSystem
Library             String

Suite Setup         Suite Initialization


*** Tasks ***
Check Deployment Log For Issues with `${DEPLOYMENT_NAME}`
    [Documentation]    Fetches recent logs for the given deployment in the namespace and checks the logs output for issues.
    [Tags]
    ...    fetch
    ...    log
    ...    pod
    ...    container
    ...    errors
    ...    inspect
    ...    trace
    ...    info
    ...    deployment
    ...    ${DEPLOYMENT_NAME}
    ${logs}=    RW.CLI.Run Bash File
    ...    bash_file=deployment_logs.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ${recommendations}=    RW.CLI.Run Cli
    ...    cmd=echo '''${logs.stdout}''' | awk "/Recommended Next Steps:/ {start=1; getline} start"
    ...    env=${env}
    ...    include_in_history=false
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=echo '''${logs.stdout}''' | awk '/Issues Identified:/ {start=1; next} /The namespace online-boutique has produced the following interesting events:/ {start=0} start'
    ...    env=${env}
    ...    include_in_history=false
    #FIXME: Refactor this to a loop of 1 issue per line of issue output - better alinging next steps with specific issues
    RW.CLI.Parse Cli Output By Line
    ...    rsp=${logs}
    ...    set_severity_level=2
    ...    set_issue_expected=No logs matching error patterns found in deployment ${DEPLOYMENT_NAME} in namespace: ${NAMESPACE}
    ...    set_issue_actual=Error logs found in deployment ${DEPLOYMENT_NAME} in namespace: ${NAMESPACE}
    ...    set_issue_title=Deployment ${DEPLOYMENT_NAME} in ${NAMESPACE} has: \n${issues.stdout}
    ...    set_issue_details=Deployment ${DEPLOYMENT_NAME} has error logs:\n\n$_stdout
    ...    set_issue_next_steps=${recommendations.stdout}
    ...    _line__raise_issue_if_contains=Recommended
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report
    ...    Recent logs from deployment/${DEPLOYMENT_NAME} in ${NAMESPACE}:\n\n${logs.stdout}
    RW.Core.Add Pre To Report    Commands Used: ${history}

# Fetch Previous Logs for Deployment `${DEPLOYMENT_NAME}`

Check Liveness Probe Configuration for Deployment `${DEPLOYMENT_NAME}`
    [Documentation]    Validates if a Liveliness probe has possible misconfigurations
    [Tags]
    ...    liveliness
    ...    probe
    ...    workloads
    ...    errors
    ...    failure
    ...    restart
    ...    get
    ...    deployment
    ...    ${DEPLOYMENT_NAME}
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
    IF     len($recommendations.stdout) > 0 
        RW.Core.Add Issue
        ...    severity=2
        ...    expected=Liveness probes should be configured and functional for deployment `${DEPLOYMENT_NAME}` in namespace `${NAMESPACE}`
        ...    actual=Issues found with liveness probe configuration for Deployment `${DEPLOYMENT_NAME}` in namespace `${NAMESPACE}`
        ...    title=Liveness Probe Configuration Issues with Deployment `${DEPLOYMENT_NAME}` in namespace `${NAMESPACE}`
        ...    reproduce_hint=View Commands Used in Report Output
        ...    details=${liveness_probe_health.stdout}
        ...    next_steps=${recommendations.stdout}
    END
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Liveness probe testing results:\n\n${liveness_probe_health.stdout}
    RW.Core.Add Pre To Report    Commands Used: ${history}
Check Readiness Probe Configuration for Deployment `${DEPLOYMENT_NAME}`
    [Documentation]    Validates if a readiness probe has possible misconfigurations
    [Tags]
    ...    readiness
    ...    probe
    ...    workloads
    ...    errors
    ...    failure
    ...    restart
    ...    get
    ...    deployment
    ...    ${DEPLOYMENT_NAME}
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
    IF     len($recommendations.stdout) > 0 
        RW.Core.Add Issue
        ...    severity=2
        ...    expected=Readiness probes should be configured and functional for deployment `${DEPLOYMENT_NAME}` in namespace `${NAMESPACE}`
        ...    actual=Issues found with readiness probe configuration for Deployment `${DEPLOYMENT_NAME}` in namespace `${NAMESPACE}`
        ...    title=Readiness Probe Configuration Issues with Deployment `${DEPLOYMENT_NAME}` in namespace `${NAMESPACE}`
        ...    reproduce_hint=View Commands Used in Report Output
        ...    details=${readiness_probe_health.stdout}
        ...    next_steps=${recommendations.stdout}
    END
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Readiness probe testing results:\n\n${readiness_probe_health.stdout}
    RW.Core.Add Pre To Report    Commands Used: ${history}
Troubleshoot Deployment Warning Events for `${DEPLOYMENT_NAME}`
    [Documentation]    Fetches warning events related to the deployment workload in the namespace and triages any issues found in the events.
    [Tags]    events    workloads    errors    warnings    get    deployment    ${deployment_name}
    ${events}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get events --context ${CONTEXT} -n ${NAMESPACE} -o json | jq '(now - (60*60)) as $time_limit | [ .items[] | select(.type == "Warning" and (.involvedObject.kind == "Deployment" or .involvedObject.kind == "ReplicaSet" or .involvedObject.kind == "Pod") and (.involvedObject.name | tostring | contains("${DEPLOYMENT_NAME}")) and (.lastTimestamp | fromdateiso8601) >= $time_limit) | {kind: .involvedObject.kind, name: .involvedObject.name, reason: .reason, message: .message, firstTimestamp: .firstTimestamp, lastTimestamp: .lastTimestamp} ] | group_by([.kind, .name]) | map({kind: .[0].kind, name: .[0].name, count: length, reasons: map(.reason) | unique, messages: map(.message) | unique, firstTimestamp: map(.firstTimestamp | fromdateiso8601) | sort | .[0] | todateiso8601, lastTimestamp: map(.lastTimestamp | fromdateiso8601) | sort | reverse | .[0] | todateiso8601})'
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    render_in_commandlist=true
    ${object_list}=    Evaluate    json.loads(r'''${events.stdout}''')    json
    IF    len(@{object_list}) > 0
        FOR    ${item}    IN    @{object_list}
            ${message_string}=    Catenate    SEPARATOR;    @{item["messages"]}   
            ${messages}=    Replace String    ${message_string}    "    ${EMPTY}
            ${item_next_steps}=    RW.CLI.Run Bash File
            ...    bash_file=workload_next_steps.sh
            ...    cmd_overide=./workload_next_steps.sh "${messages}" "Deployment" "${DEPLOYMENT_NAME}"
            ...    env=${env}
            ...    include_in_history=False
            # FIXME - Should we add severity mappings in the next steps to make the issue more dynamic?
            RW.Core.Add Issue
            ...    severity=4
            ...    expected=Warning events should not be present in namespace `${NAMESPACE}` for Deployment `${DEPLOYMENT_NAME}`
            ...    actual=Warning events are found in namespace `${NAMESPACE}` for Deployment `${DEPLOYMENT_NAME}` which indicate potential issues.
            ...    title= Deployment `${DEPLOYMENT_NAME}` generated warning events for ${item["kind"]} `${item["name"]}`.
            ...    reproduce_hint=View Commands Used in Report Output
            ...    details=${item["kind"]} `${item["name"]}` generated the following warning details:\n`${item}`
            ...    next_steps=${item_next_steps.stdout}
        END
    END
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    ${events.stdout}
    RW.Core.Add Pre To Report    Commands Used: ${history}

Get Deployment Workload Details For `${DEPLOYMENT_NAME}` and Add to Report
    [Documentation]    Fetches the current state of the deployment for future review in the report.
    [Tags]    deployment    details    manifest    info    ${DEPLOYMENT_NAME}
    ${deployment}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get deployment/${DEPLOYMENT_NAME} --context ${CONTEXT} -n ${NAMESPACE} -o yaml
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    render_in_commandlist=true
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Snapshot of deployment state:\n\n${deployment.stdout}
    RW.Core.Add Pre To Report    Commands Used: ${history}

Troubleshoot Deployment Replicas for `${DEPLOYMENT_NAME}`
    [Documentation]    Pulls the replica information for a given deployment and checks if it's highly available
    ...    , if the replica counts are the expected / healthy values, and raises issues if it is not progressing 
    ...    and is missing pods. 
    [Tags]
    ...    deployment
    ...    replicas
    ...    desired
    ...    actual
    ...    available
    ...    ready
    ...    unhealthy
    ...    rollout
    ...    stuck
    ...    pods
    ...    ${DEPLOYMENT_NAME}
    ${deployment_replicas}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get deployment/${DEPLOYMENT_NAME} --context ${CONTEXT} -n ${NAMESPACE} -o json | jq '.status | {desired_replicas: .replicas, ready_replicas: (.readyReplicas // 0), missing_replicas: ((.replicas // 0) - (.readyReplicas // 0)), unavailable_replicas: (.unavailableReplicas // 0), available_condition: (if any(.conditions[]; .type == "Available") then (.conditions[] | select(.type == "Available")) else "Condition not available" end), progressing_condition: (if any(.conditions[]; .type == "Progressing") then (.conditions[] | select(.type == "Progressing")) else "Condition not available" end)}'
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    env=${env}
    ...    render_in_commandlist=true
    ${deployment_status}=    Evaluate    json.loads(r'''${deployment_replicas.stdout}''')    json
    IF    $deployment_status["available_condition"]["status"] == "False" and $deployment_status["progressing_condition"]["status"] == "False"
        ${item_next_steps}=    RW.CLI.Run Bash File
        ...    bash_file=workload_next_steps.sh
        ...    cmd_overide=./workload_next_steps.sh "${deployment_status["available_condition"]["message"]}" "Deployment" "${DEPLOYMENT_NAME}"
        ...    env=${env}
        ...    include_in_history=False
        RW.Core.Add Issue
        ...    severity=1
        ...    expected=Deployment `${DEPLOYMENT_NAME}` in namespace `${NAMESPACE}` should have minimum availability / pod.
        ...    actual=Deployment `${DEPLOYMENT_NAME}` in namespace `${NAMESPACE}` does not have minimum availability / pods.
        ...    title= Deployment `${DEPLOYMENT_NAME}` has status: ${deployment_status["available_condition"]["message"]}
        ...    reproduce_hint=View Commands Used in Report Output
        ...    details=Deployment `${DEPLOYMENT_NAME}` has ${deployment_status["ready_replicas"]} pods and needs ${deployment_status["desired_replicas"]}:\n`${deployment_status}`
        ...    next_steps=${item_next_steps.stdout}
    ELSE IF    $deployment_status["unavailable_replicas"] > 0 and $deployment_status["available_condition"]["status"] == "True" and $deployment_status["progressing_condition"]["status"] == "False"
        RW.Core.Add Issue
        ...    severity=3
        ...    expected=Deployment `${DEPLOYMENT_NAME}` in namespace `${NAMESPACE}` should have ${deployment_status["desired_replicas"]} pods.
        ...    actual=Deployment `${DEPLOYMENT_NAME}` in namespace `${NAMESPACE}` has ${deployment_status["ready_replicas"]} pods.
        ...    title= Deployment `${DEPLOYMENT_NAME}` has ${deployment_status["unavailable_replicas"]} unavailable pods.
        ...    reproduce_hint=View Commands Used in Report Output
        ...    details=Deployment `${DEPLOYMENT_NAME}` has minimum availability, but has unready pods:\n`${deployment_status}`
        ...    next_steps=Troubleshoot Deployment Warning Events for `${DEPLOYMENT_NAME}`
    END
    IF    $deployment_status["desired_replicas"] == 1
        RW.Core.Add Issue
        ...    severity=4
        ...    expected=Deployment `${DEPLOYMENT_NAME}` in namespace `${NAMESPACE}` should have more than 1 desired pod.
        ...    actual=Deployment `${DEPLOYMENT_NAME}` in namespace `${NAMESPACE}` is configured to have only 1 pod.
        ...    title= Deployment `${DEPLOYMENT_NAME}` is not configured to be highly available.
        ...    reproduce_hint=View Commands Used in Report Output
        ...    details=Deployment `${DEPLOYMENT_NAME}` is only configured to have a single pod:\n`${deployment_status}`
        ...    next_steps=Get Deployment Workload Details For `${DEPLOYMENT_NAME}` and Add to Report\nAdjust Deployment `${DEPLOYMENT_NAME}` spec.replicas to be greater than 1.
    END
    RW.Core.Add Pre To Report    Deployment State:\n${deployment_replicas.stdout}
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Commands Used: ${history}

Check Deployment Event Anomalies for `${DEPLOYMENT_NAME}`
    [Documentation]    Parses all events in a namespace within a timeframe and checks for unusual activity, raising issues for any found.
    [Tags]
    ...    deployment
    ...    events
    ...    info
    ...    state
    ...    anomolies
    ...    count
    ...    occurences
    ...    <service_name>
    ...    we found the following distinctly counted errors in the service workloads of namespace
    ...    connection error
    ...    ${DEPLOYMENT_NAME}
    ${recent_anomalies}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get events --context ${CONTEXT} -n ${NAMESPACE} -o json | jq '(now - (60*60)) as $time_limit | [ .items[] | select(.type != "Warning" and (.involvedObject.kind == "Deployment" or .involvedObject.kind == "ReplicaSet" or .involvedObject.kind == "Pod") and (.involvedObject.name | tostring | contains("${DEPLOYMENT_NAME}"))) | {kind: .involvedObject.kind, count: .count, name: .involvedObject.name, reason: .reason, message: .message, firstTimestamp: .firstTimestamp, lastTimestamp: .lastTimestamp, duration: (if (((.lastTimestamp | fromdateiso8601) - (.firstTimestamp | fromdateiso8601)) == 0) then 1 else (((.lastTimestamp | fromdateiso8601) - (.firstTimestamp | fromdateiso8601))/60) end) } ] | group_by([.kind, .name]) | map({kind: .[0].kind, name: .[0].name, count: (map(.count) | add), reasons: map(.reason) | unique, messages: map(.message) | unique, average_events_per_minute: (if .[0].duration == 1 then 1 else ((map(.count) | add)/.[0].duration ) end),firstTimestamp: map(.firstTimestamp | fromdateiso8601) | sort | .[0] | todateiso8601, lastTimestamp: map(.lastTimestamp | fromdateiso8601) | sort | reverse | .[0] | todateiso8601})'
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    render_in_commandlist=true
    ${anomaly_list}=    Evaluate    json.loads(r'''${recent_anomalies.stdout}''')    json
    IF    len($anomaly_list) > 0
        FOR    ${item}    IN    @{anomaly_list}
            IF    $item["average_events_per_minute"] > ${ANOMALY_THRESHOLD}
                ${messages}=    Replace String    ${item["messages"][0]}    "    ${EMPTY}
                ${item_next_steps}=    RW.CLI.Run Bash File
                ...    bash_file=workload_next_steps.sh
                ...    cmd_overide=./workload_next_steps.sh "${messages}" "Deployment" "${DEPLOYMENT_NAME}"
                ...    env=${env}
                ...    include_in_history=False
                RW.Core.Add Issue
                ...    severity=3
                ...    expected=Deployment `${DEPLOYMENT_NAME}` in namespace `${NAMESPACE}` has generated an average events per minute above the threshold of ${ANOMALY_THRESHOLD}.
                ...    actual=Deployment `${DEPLOYMENT_NAME}` in namespace `${NAMESPACE}` should have less than ${ANOMALY_THRESHOLD} events per minute related to a specific object.
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
    ${DEPLOYMENT_NAME}=    RW.Core.Import User Variable    DEPLOYMENT_NAME
    ...    type=string
    ...    description=Used to target the resource for queries and filtering events.
    ...    pattern=\w*
    ...    example=artifactory
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
    ${EXPECTED_AVAILABILITY}=    RW.Core.Import User Variable    EXPECTED_AVAILABILITY
    ...    type=string
    ...    description=The minimum numbers of replicas allowed considered healthy.
    ...    pattern=\d+
    ...    example=3
    ...    default=3
    ${ANOMALY_THRESHOLD}=    RW.Core.Import User Variable
    ...    ANOMALY_THRESHOLD
    ...    type=string
    ...    description=The rate of occurence per minute at which an Event becomes classified as an anomaly, even if Kubernetes considers it informational.
    ...    pattern=\d+(\.\d+)?
    ...    example=5.0
    ...    default=5.0
    ${LOGS_ERROR_PATTERN}=    RW.Core.Import User Variable    LOGS_ERROR_PATTERN
    ...    type=string
    ...    description=The error pattern to use when grep-ing logs.
    ...    pattern=\w*
    ...    example=(Error: 13|Error: 14)
    ...    default=(ERROR)
    ${LOGS_EXCLUDE_PATTERN}=    RW.Core.Import User Variable    LOGS_EXCLUDE_PATTERN
    ...    type=string
    ...    description=Pattern used to exclude entries from log results when searching in log results.
    ...    pattern=\w*
    ...    example=(node_modules|opentelemetry)
    ...    default=(node_modules|opentelemetry)
    ${KUBERNETES_DISTRIBUTION_BINARY}=    RW.Core.Import User Variable    KUBERNETES_DISTRIBUTION_BINARY
    ...    type=string
    ...    description=Which binary to use for Kubernetes CLI commands.
    ...    enum=[kubectl,oc]
    ...    example=kubectl
    ...    default=kubectl
    ${HOME}=    RW.Core.Import User Variable    HOME
    Set Suite Variable    ${kubeconfig}    ${kubeconfig}
    Set Suite Variable    ${kubectl}    ${kubectl}
    Set Suite Variable    ${KUBERNETES_DISTRIBUTION_BINARY}    ${KUBERNETES_DISTRIBUTION_BINARY}
    Set Suite Variable    ${CONTEXT}    ${CONTEXT}
    Set Suite Variable    ${NAMESPACE}    ${NAMESPACE}
    Set Suite Variable    ${DEPLOYMENT_NAME}    ${DEPLOYMENT_NAME}
    Set Suite Variable    ${EXPECTED_AVAILABILITY}    ${EXPECTED_AVAILABILITY}
    Set Suite Variable    ${ANOMALY_THRESHOLD}    ${ANOMALY_THRESHOLD}
    Set Suite Variable    ${LOGS_ERROR_PATTERN}    ${LOGS_ERROR_PATTERN}
    Set Suite Variable    ${LOGS_EXCLUDE_PATTERN}    ${LOGS_EXCLUDE_PATTERN}
    Set Suite Variable    ${HOME}    ${HOME}
    Set Suite Variable
    ...    ${env}
    ...    {"KUBECONFIG":"./${kubeconfig.key}", "KUBERNETES_DISTRIBUTION_BINARY":"${KUBERNETES_DISTRIBUTION_BINARY}", "CONTEXT":"${CONTEXT}", "NAMESPACE":"${NAMESPACE}", "LOGS_ERROR_PATTERN":"${LOGS_ERROR_PATTERN}", "LOGS_EXCLUDE_PATTERN":"${LOGS_EXCLUDE_PATTERN}", "ANOMALY_THRESHOLD":"${ANOMALY_THRESHOLD}", "DEPLOYMENT_NAME": "${DEPLOYMENT_NAME}", "HOME":"${HOME}"}
