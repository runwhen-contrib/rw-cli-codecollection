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
Library             RW.K8sHelper
Library             OperatingSystem
Library             String

Suite Setup         Suite Initialization
Suite Teardown      Suite Teardown


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
    ...    cmd_override=./deployment_logs.sh | tee "${SCRIPT_TMP_DIR}/log_analysis"
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ${recommendations}=    RW.CLI.Run Cli
    ...    cmd=awk "/Recommended Next Steps:/ {start=1; getline} start" "${SCRIPT_TMP_DIR}/log_analysis"
    ...    env=${env}
    ...    include_in_history=false
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=awk '/Issues Identified:/ {start=1; next} /The namespace `${NAMESPACE}` has produced the following interesting events:/ {start=0} start' "${SCRIPT_TMP_DIR}/log_analysis"
    ...    env=${env}
    ...    include_in_history=false
    IF    len($issues.stdout) > 0
        RW.Core.Add Issue
        ...    severity=3
        ...    expected=No logs matching error patterns found in deployment `${DEPLOYMENT_NAME}` in namespace `${NAMESPACE}`
        ...    actual=Error logs found in deployment `${DEPLOYMENT_NAME}` in namespace `${NAMESPACE}`
        ...    title=Deployment `${DEPLOYMENT_NAME}` in `${NAMESPACE}` is generating error logs.
        ...    reproduce_hint=View Commands Used in Report Output
        ...    details=Deployment ${DEPLOYMENT_NAME} in Namespace ${NAMESPACE} generated the following log analysis: \n${logs.stdout}
        ...    next_steps=${recommendations.stdout}
    END
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report
    ...    Recent logs from Deployment ${DEPLOYMENT_NAME} in Namespace ${NAMESPACE}:\n\n${logs.stdout}
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
    ...    cmd_override=./validate_probes.sh livenessProbe | tee "${SCRIPT_TMP_DIR}/liveness_probe_output"
    ...    env=${env}
    ...    include_in_history=False
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    show_in_rwl_cheatsheet=true
    ${recommendations}=    RW.CLI.Run Cli
    ...    cmd=awk '/Recommended Next Steps:/ {flag=1; next} flag' "${SCRIPT_TMP_DIR}/liveness_probe_output"
    ...    env=${env}
    ...    include_in_history=false
    IF    len($recommendations.stdout) > 0
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
    RW.Core.Add Pre To Report    Commands Used: ${liveness_probe_health.cmd}

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
    ...    cmd_override=./validate_probes.sh readinessProbe | tee "${SCRIPT_TMP_DIR}/readiness_probe_output"
    ...    env=${env}
    ...    include_in_history=False
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    show_in_rwl_cheatsheet=true
    ${recommendations}=    RW.CLI.Run Cli
    ...    cmd=awk '/Recommended Next Steps:/ {flag=1; next} flag' "${SCRIPT_TMP_DIR}/readiness_probe_output"
    ...    env=${env}
    ...    include_in_history=false
    IF    len($recommendations.stdout) > 0
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
    RW.Core.Add Pre To Report    Commands Used: ${readiness_probe_health.cmd}

Troubleshoot Deployment Warning Events for `${DEPLOYMENT_NAME}`
    [Documentation]    Fetches warning events related to the deployment workload in the namespace and triages any issues found in the events.
    [Tags]    events    workloads    errors    warnings    get    deployment    ${DEPLOYMENT_NAME}
    ${events}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get events --context ${CONTEXT} -n ${NAMESPACE} -o json | jq '(now - (60*60)) as $time_limit | [ .items[] | select(.type == "Warning" and (.involvedObject.kind == "Deployment" or .involvedObject.kind == "ReplicaSet" or .involvedObject.kind == "Pod") and (.involvedObject.name | tostring | contains("${DEPLOYMENT_NAME}")) and (.lastTimestamp | fromdateiso8601) >= $time_limit) | {kind: .involvedObject.kind, name: .involvedObject.name, reason: .reason, message: .message, firstTimestamp: .firstTimestamp, lastTimestamp: .lastTimestamp} ] | group_by([.kind, .name]) | map({kind: .[0].kind, name: .[0].name, count: length, reasons: map(.reason) | unique, messages: map(.message) | unique, firstTimestamp: map(.firstTimestamp | fromdateiso8601) | sort | .[0] | todateiso8601, lastTimestamp: map(.lastTimestamp | fromdateiso8601) | sort | reverse | .[0] | todateiso8601})'
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    show_in_rwl_cheatsheet=true
    ...    render_in_commandlist=true
   ${k8s_deployment_details}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get deployment ${DEPLOYMENT_NAME} -n ${NAMESPACE} --context ${CONTEXT} -o json
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ${related_resource_recommendations}=    RW.K8sHelper.Get Related Resource Recommendations
    ...    k8s_object=${k8s_deployment_details.stdout}
    ${object_list}=    Evaluate    json.loads(r'''${events.stdout}''')    json
    IF    len(@{object_list}) > 0
        FOR    ${item}    IN    @{object_list}
            ${message_string}=    Catenate    SEPARATOR;    @{item["messages"]}
            ${messages}=    Replace String    ${message_string}    "    ${EMPTY}
            ${item_next_steps}=    RW.CLI.Run Bash File
            ...    bash_file=workload_next_steps.sh
            ...    cmd_override=./workload_next_steps.sh "${messages}" "Deployment" "${DEPLOYMENT_NAME}"
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
            ...    next_steps=${item_next_steps.stdout}\n${related_resource_recommendations}
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
    ...    show_in_rwl_cheatsheet=true
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
    ...    show_in_rwl_cheatsheet=true
    ...    render_in_commandlist=true
    ${deployment_status}=    Evaluate    json.loads(r'''${deployment_replicas.stdout}''')    json
    IF    $deployment_status["available_condition"]["status"] == "False" or $deployment_status["ready_replicas"] == "0"
        ${item_next_steps}=    RW.CLI.Run Bash File
        ...    bash_file=workload_next_steps.sh
        ...    cmd_override=./workload_next_steps.sh "${deployment_status["available_condition"]["message"]}" "Deployment" "${DEPLOYMENT_NAME}"
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
    ...    connection error
    ...    ${DEPLOYMENT_NAME}
    ${recent_anomalies}=    RW.CLI.Run Bash File
    ...    bash_file=event_anomalies.sh 
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
   ${k8s_deployment_details}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get deployment ${DEPLOYMENT_NAME} -n ${NAMESPACE} --context ${CONTEXT} -o json
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ${related_resource_recommendations}=    RW.K8sHelper.Get Related Resource Recommendations
    ...    k8s_object=${k8s_deployment_details.stdout}
    ${anomaly_list}=    Evaluate    json.loads(r'''${recent_anomalies.stdout}''')    json
    IF    len($anomaly_list) > 0
        FOR    ${item}    IN    @{anomaly_list}
            IF    $item["average_events_per_minute"] > ${ANOMALY_THRESHOLD}
                ${messages}=    Replace String    ${item["messages"][0]}    "    ${EMPTY}
                ${item_next_steps}=    RW.CLI.Run Bash File
                ...    bash_file=workload_next_steps.sh
                ...    cmd_override=./workload_next_steps.sh "${messages}" "Deployment" "${DEPLOYMENT_NAME}"
                ...    env=${env}
                ...    include_in_history=False
                RW.Core.Add Issue
                ...    severity=3
                ...    expected=Deployment `${DEPLOYMENT_NAME}` in namespace `${NAMESPACE}` has generated an average events per minute above the threshold of ${ANOMALY_THRESHOLD}.
                ...    actual=Deployment `${DEPLOYMENT_NAME}` in namespace `${NAMESPACE}` should have less than ${ANOMALY_THRESHOLD} events per minute related to a specific object.
                ...    title= ${item["kind"]} `${item["name"]}` has an average of ${item["average_events_per_minute"]} events per minute (above the threshold of ${ANOMALY_THRESHOLD})
                ...    reproduce_hint=View Commands Used in Report Output
                ...    details=${item["kind"]} `${item["name"]}` has ${item["count"]} normal events that should be reviewed:\n`${item}`
                ...    next_steps=${item_next_steps.stdout}\n${related_resource_recommendations}
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

Check ReplicaSet Health for Deployment `${DEPLOYMENT_NAME}`
    [Documentation]    Fetches all replicasets related to deployment to ensure that conflicting versions don't exist. 
    [Tags]
    ...    replica
    ...    replicaset
    ...    versions
    ...    container
    ...    pods
    ...    deployment
    ...    ${DEPLOYMENT_NAME}
    ${check_replicaset}=    RW.CLI.Run Bash File
    ...    bash_file=check_replicaset.sh 
    ...    cmd_override=./check_replicaset.sh | tee "${SCRIPT_TMP_DIR}/rs_analysis"
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ${recommendations}=    RW.CLI.Run Cli
    ...    cmd=awk "/Recommended Next Steps:/ {start=1; getline} start" "${SCRIPT_TMP_DIR}/rs_analysis"
    ...    env=${env}
    ...    include_in_history=false
    IF    $recommendations.stdout != ""
        ${recommendation_list}=    Evaluate    json.loads(r'''${recommendations.stdout}''')    json
        IF    len(@{recommendation_list}) > 0
            FOR    ${item}    IN    @{recommendation_list}
                RW.Core.Add Issue
                ...    severity=${item["severity"]}
                ...    expected=Deployment `${DEPLOYMENT_NAME}` should only have one active replicaset in namespace `${NAMESPACE}`
                ...    actual=Deployment `${DEPLOYMENT_NAME}` has more than one active replicaset in namespace `${NAMESPACE}`
                ...    title=${item["title"]}
                ...    reproduce_hint=${check_replicaset.cmd}
                ...    details=${item["details"]}
                ...    next_steps=${item["next_steps"]}
            END
        END
    END
    RW.Core.Add Pre To Report    ${check_replicaset.stdout}\n
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
    ...    default=("")
    ${LOGS_EXCLUDE_PATTERN}=    RW.Core.Import User Variable    LOGS_EXCLUDE_PATTERN
    ...    type=string
    ...    description=Pattern used to exclude entries from log results when searching in log results.
    ...    pattern=\w*
    ...    example=(node_modules|opentelemetry)
    ...    default=("")
    ${KUBERNETES_DISTRIBUTION_BINARY}=    RW.Core.Import User Variable    KUBERNETES_DISTRIBUTION_BINARY
    ...    type=string
    ...    description=Which binary to use for Kubernetes CLI commands.
    ...    enum=[kubectl,oc]
    ...    example=kubectl
    ...    default=kubectl
    ${HOME}=    RW.Core.Import User Variable    HOME
    ...    type=string
    ...    description=The home path of the runner
    ...    pattern=\w*
    ...    example=/root
    ...    default=/root    
    Set Suite Variable    ${kubeconfig}    ${kubeconfig}
    Set Suite Variable    ${KUBERNETES_DISTRIBUTION_BINARY}    ${KUBERNETES_DISTRIBUTION_BINARY}
    Set Suite Variable    ${CONTEXT}    ${CONTEXT}
    Set Suite Variable    ${NAMESPACE}    ${NAMESPACE}
    Set Suite Variable    ${DEPLOYMENT_NAME}    ${DEPLOYMENT_NAME}
    Set Suite Variable    ${EXPECTED_AVAILABILITY}    ${EXPECTED_AVAILABILITY}
    Set Suite Variable    ${ANOMALY_THRESHOLD}    ${ANOMALY_THRESHOLD}
    Set Suite Variable    ${LOGS_ERROR_PATTERN}    ${LOGS_ERROR_PATTERN}
    Set Suite Variable    ${LOGS_EXCLUDE_PATTERN}    ${LOGS_EXCLUDE_PATTERN}
    Set Suite Variable    ${HOME}    ${HOME}
    ${temp_dir}=    RW.CLI.Run Cli    cmd=mktemp -d ${HOME}/k8s-deployment-healthcheck-XXXXXXXXXX | tr -d '\n'
    Set Suite Variable    ${SCRIPT_TMP_DIR}    ${temp_dir.stdout}
    Set Suite Variable
    ...    ${env}
    ...    {"KUBECONFIG":"./${kubeconfig.key}", "KUBERNETES_DISTRIBUTION_BINARY":"${KUBERNETES_DISTRIBUTION_BINARY}", "CONTEXT":"${CONTEXT}", "NAMESPACE":"${NAMESPACE}", "LOGS_ERROR_PATTERN":"${LOGS_ERROR_PATTERN}", "LOGS_EXCLUDE_PATTERN":"${LOGS_EXCLUDE_PATTERN}", "ANOMALY_THRESHOLD":"${ANOMALY_THRESHOLD}", "DEPLOYMENT_NAME": "${DEPLOYMENT_NAME}", "HOME":"${HOME}"}
Suite Teardown
     RW.CLI.Run Cli    cmd=rm -rf ${SCRIPT_TMP_DIR}