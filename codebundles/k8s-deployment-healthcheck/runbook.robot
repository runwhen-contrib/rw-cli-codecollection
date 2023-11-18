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
    [Tags]    fetch    log    pod    container    errors    inspect    trace    info    deployment    ${DEPLOYMENT_NAME}
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
    ...    cmd=echo '''${logs.stdout}''' | awk '/Issues Identified:/ {start=1} /The namespace online-boutique has produced the following interesting events:/ {start=0} start'
    ...    env=${env}
    ...    include_in_history=false
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


# Check Liveliness Probe Configuration for Deployment `${DEPLOYMENT_NAME}`


# Check Readiness Probe Configuration for Deployment `${DEPLOYMENT_NAME}`

Troubleshoot Deployment Warning Events for `${DEPLOYMENT_NAME}`
    [Documentation]    Fetches warning events related to the deployment workload in the namespace and triages any issues found in the events.
    [Tags]    events    workloads    errors    warnings    get    deployment    ${DEPLOYMENT_NAME}
    ${events}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get events --context ${CONTEXT} -n ${NAMESPACE} -o json | jq '(now - (60*60)) as $time_limit | [ .items[] | select(.type == "Warning" and (.involvedObject.kind == "Deployment" or .involvedObject.kind == "ReplicaSet" or .involvedObject.kind == "Pod") and (.involvedObject.name | tostring | contains("${DEPLOYMENT_NAME}")) and (.lastTimestamp | fromdateiso8601) >= $time_limit) | {kind: .involvedObject.kind, name: .involvedObject.name, reason: .reason, message: .message, firstTimestamp: .firstTimestamp, lastTimestamp: .lastTimestamp} ] | group_by([.kind, .name]) | map({kind: .[0].kind, name: .[0].name, count: length, reasons: map(.reason) | unique, messages: map(.message) | unique, firstTimestamp: map(.firstTimestamp | fromdateiso8601) | sort | .[0] | todateiso8601, lastTimestamp: map(.lastTimestamp | fromdateiso8601) | sort | reverse | .[0] | todateiso8601})'
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    render_in_commandlist=true
    ${object_list}=    Evaluate    json.loads(r'''${events.stdout}''')    json
    IF    len(@{object_list}) > 0
        FOR    ${item}    IN    @{object_list}
            # ${messages}=    Replace String    ${item["messages"]}    "    ${EMPTY}
            ${item_next_steps}=    RW.CLI.Run Bash File
            ...    bash_file=workload_next_steps.sh
            ...    cmd_overide=./workload_next_steps.sh "${item["messages"]}" "${item["kind"]}" "${item["name"]}"
            ...    env=${env}
            ...    secret_file__kubeconfig=${kubeconfig}
            ...    include_in_history=False
            RW.Core.Add Issue
            ...    severity=4
            ...    expected=Warning events should not be present in namespace `${NAMESPACE}` for Deployment `${DEPLOYMENT_NAME}`
            ...    actual=Warning events are found in namespace `${NAMESPACE}` for Deployment `${DEPLOYMENT_NAME}` which indicate potential issues.
            ...    title= deployment `${DEPLOYMENT_NAME}` generated warning events for ${item["kind"]} `${item["name"]}`.
            ...    reproduce_hint=View Commands Used in Report Output
            ...    details=${item["kind"]} `${item["name"]}` generated the following warning details:\n`${item}`
            ...    next_steps=${item_next_steps.stdout}
        END
    END
    # ${next_steps}=    RW.NextSteps.Suggest    ${events.stdout}
    # ${next_steps}=    RW.NextSteps.Format    ${next_steps}
    # ...    deployment_name=${DEPLOYMENT_NAME}
    # RW.CLI.Parse Cli Output By Line
    # ...    rsp=${events}
    # ...    set_severity_level=1
    # ...    set_issue_expected=No events of type warning should exist for deployment.
    # ...    set_issue_actual=Events of type warning found for deployment.
    # ...    set_issue_title=The deployment ${DEPLOYMENT_NAME} has warning events
    # ...    set_issue_details=Warning events found for deployment ${DEPLOYMENT_NAME} in namespace ${NAMESPACE}\n$_line\n
    # ...    set_issue_next_steps=${next_steps}
    # ...    _line__raise_issue_if_contains=Warning
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
    ...    , if the replica counts are the expected / healthy values, and if not, what they should be.
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
    ${deployment}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get deployment/${DEPLOYMENT_NAME} --context ${CONTEXT} -n ${NAMESPACE} -o json
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    render_in_commandlist=true
    ${no_replicas_next_steps}=    RW.NextSteps.Suggest    Pods not running for deployment/${DEPLOYMENT_NAME}
    ${no_replicas_next_steps}=    RW.NextSteps.Format    ${no_replicas_next_steps}
    ...    deployment_name=${DEPLOYMENT_NAME}
    ${available_replicas}=    RW.CLI.Parse Cli Json Output
    ...    rsp=${deployment}
    ...    extract_path_to_var__available_replicas=status.availableReplicas || `0`
    ...    available_replicas__raise_issue_if_lt=1
    ...    assign_stdout_from_var=available_replicas
    ...    set_issue_title=No replicas available for deployment/${DEPLOYMENT_NAME}
    ...    set_issue_details=No replicas available for deployment/${DEPLOYMENT_NAME} in namespace ${NAMESPACE}, we found 0.
    ...    set_issue_next_steps=${no_replicas_next_steps}
    RW.CLI.Parse Cli Json Output
    ...    rsp=${available_replicas}
    ...    extract_path_to_var__available_replicas=@
    ...    available_replicas__raise_issue_if_lt=${EXPECTED_AVAILABILITY}
    ...    set_issue_title=Fewer Than Expected Available Replicas For Deployment ${DEPLOYMENT_NAME}
    ...    set_issue_details=Fewer than expected replicas available (we found $available_replicas) for deployment ${DEPLOYMENT_NAME} in namespace ${NAMESPACE} - check manifests, kubernetes events, pod logs, resource constraints and PersistentVolumes
    ...    set_issue_next_steps=Troubleshoot Container Restarts in Namespace\n\nnamespace:${NAMESPACE}
    ${desired_replicas}=    RW.CLI.Parse Cli Json Output
    ...    rsp=${deployment}
    ...    extract_path_to_var__desired_replicas=status.replicas || `0`
    ...    desired_replicas__raise_issue_if_lt=1
    ...    assign_stdout_from_var=desired_replicas
    ...    set_issue_title=Less than desired replicas for deployment/${DEPLOYMENT_NAME}
    ...    set_issue_details=Less than desired replicas for deployment/${DEPLOYMENT_NAME} in ${NAMESPACE}.
    ...    set_issue_next_steps=Troubleshoot Deployment Warning Events\n\n Deployment:${DEPLOYMENT_NAME}
    RW.CLI.Parse Cli Json Output
    ...    rsp=${desired_replicas}
    ...    extract_path_to_var__desired_replicas=@
    ...    desired_replicas__raise_issue_if_neq=${available_replicas.stdout}
    ...    set_issue_title=Desired and ready pods for deployment/${DEPLOYMENT_NAME} do not match as expected
    ...    set_issue_details=Desired and ready pods for deployment/${DEPLOYMENT_NAME} do not match in namespace ${NAMESPACE}, desired: $desired_replicas vs ready: ${available_replicas.stdout}. We got ready:${available_replicas.stdout} vs desired: $desired_replicas
    ...    set_issue_next_steps=Troubleshoot Deployment Warning Events\n\n Deployment:${DEPLOYMENT_NAME}
    ${desired_replicas}=    Convert To Number    ${desired_replicas.stdout}
    ${available_replicas}=    Convert To Number    ${available_replicas.stdout}
    RW.Core.Add Pre To Report    Deployment State:\n${deployment.stdout}
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
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get events --field-selector type!=Warning --context ${CONTEXT} -n ${NAMESPACE} -o json | jq -r '.items[] | select(.involvedObject.name|contains("${DEPLOYMENT_NAME}")) | select( .count / ( if ((.lastTimestamp|fromdate)-(.firstTimestamp|fromdate))/60 == 0 then 1 else ((.lastTimestamp|fromdate)-(.firstTimestamp|fromdate))/60 end ) > ${ANOMALY_THRESHOLD}) | "Event(s) Per Minute:" + (.count / ( if ((.lastTimestamp|fromdate)-(.firstTimestamp|fromdate))/60 == 0 then 1 else ((.lastTimestamp|fromdate)-(.firstTimestamp|fromdate))/60 end ) |tostring) +" Count:" + (.count|tostring) + " Minute(s):" + (((.lastTimestamp|fromdate)-(.firstTimestamp|fromdate))/60|tostring)+ " Object:" + .involvedObject.namespace + "/" + .involvedObject.kind + "/" + .involvedObject.name + " Reason:" + .reason + " Message:" + .message'
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    render_in_commandlist=true
    RW.CLI.Parse Cli Output By Line
    ...    rsp=${recent_anomalies}
    ...    set_severity_level=2
    ...    set_issue_expected=No unusual recent anomaly events with high counts in the namespace ${NAMESPACE}
    ...    set_issue_actual=We detected events in the namespace ${NAMESPACE} which are considered anomalies
    ...    set_issue_title=Event Anomalies Detected In Namespace ${NAMESPACE}
    ...    set_issue_details=Anomaly non-warning events in namespace ${NAMESPACE}:\n"$_stdout"
    ...    set_issue_next_steps=${DEPLOYMENT_NAME} Check Deployment Log For Issues
    ...    _line__raise_issue_if_contains=Object
    ${history}=    RW.CLI.Pop Shell History
    ${recent_anomalies}=    Set Variable    ${recent_anomalies.stdout}
    IF    """${recent_anomalies}""" == ""
        ${recent_anomalies}=    Set Variable    No anomalies were detected!
    END
    RW.Core.Add To Report    Summary Of Anomalies Detected:\n
    RW.Core.Add To Report    ${recent_anomalies}\n
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
    ...    example=1.0
    ...    default=1.0
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
