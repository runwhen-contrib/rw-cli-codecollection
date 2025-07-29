*** Settings ***
Documentation       Triages issues related to a DaemonSet and its pods, including node scheduling and resource constraints.
Metadata            Author    stewartshea
Metadata            Display Name    Kubernetes DaemonSet Triage
Metadata            Supports    Kubernetes,AKS,EKS,GKE,OpenShift

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             RW.NextSteps
Library             RW.K8sHelper
Library             RW.K8sLog
Library             OperatingSystem
Library             String
Library             Collections

Suite Setup         Suite Initialization


*** Tasks ***
Analyze Application Log Patterns for DaemonSet `${DAEMONSET_NAME}` in Namespace `${NAMESPACE}`
    [Documentation]    Fetches and analyzes logs from the DaemonSet pods for errors, stack traces, connection issues, and other patterns that indicate application health problems.
    [Tags]
    ...    logs
    ...    application
    ...    errors
    ...    patterns
    ...    health
    ...    daemonset
    ...    stacktrace
    ...    access:read-only
    ${log_dir}=    RW.K8sLog.Fetch Workload Logs
    ...    workload_type=daemonset
    ...    workload_name=${DAEMONSET_NAME}
    ...    namespace=${NAMESPACE}
    ...    context=${CONTEXT}
    ...    kubeconfig=${kubeconfig}
    ...    log_age=${LOG_AGE}
    
    ${scan_results}=    RW.K8sLog.Scan Logs For Issues
    ...    log_dir=${log_dir}
    ...    workload_type=daemonset
    ...    workload_name=${DAEMONSET_NAME}
    ...    namespace=${NAMESPACE}
    ...    categories=@{LOG_PATTERN_CATEGORIES}
    
    ${log_health_score}=    RW.K8sLog.Calculate Log Health Score    scan_results=${scan_results}
    
    # Process each issue found in the logs
    ${issues}=    Evaluate    $scan_results.get('issues', [])
    FOR    ${issue}    IN    @{issues}
        ${severity}=    Evaluate    $issue.get('severity', ${LOG_SEVERITY_THRESHOLD})
        IF    ${severity} <= ${LOG_SEVERITY_THRESHOLD}
            # Use the full issue details directly without summarization to preserve all log content
            ${issue_details_raw}=    Evaluate    $issue.get("details", "")
            ${issue_details_str}=    Convert To String    ${issue_details_raw}
            
            RW.Core.Add Issue
            ...    severity=${severity}
            ...    expected=Application logs should be free of critical errors for daemonset `${DAEMONSET_NAME}` in namespace `${NAMESPACE}`
            ...    actual=${issue.get('title', 'Log pattern issue detected')} in daemonset `${DAEMONSET_NAME}` in namespace `${NAMESPACE}`
            ...    title=${issue.get('title', 'Log Pattern Issue')} in DaemonSet `${DAEMONSET_NAME}`
            ...    reproduce_hint=Check application logs for daemonset `${DAEMONSET_NAME}` in namespace `${NAMESPACE}`
            ...    details=${issue_details_str}
            ...    next_steps=${issue.get('next_steps', 'Review application logs and resolve underlying issues')}
        END
    END

    ${issues_count}=    Get Length    ${issues}
    
    # Format scan results for better display
    ${formatted_results}=    RW.K8sLog.Format Scan Results For Display    scan_results=${scan_results}
    
    RW.Core.Add Pre To Report    **Log Analysis Summary for DaemonSet `${DAEMONSET_NAME}`**\n**Health Score:** ${log_health_score}\n**Analysis Depth:** ${LOG_ANALYSIS_DEPTH}\n**Categories Analyzed:** ${LOG_PATTERN_CATEGORIES_STR}\n**Issues Found:** ${issues_count}\n\n${formatted_results}
    
    RW.K8sLog.Cleanup Temp Files

Detect Log Anomalies for DaemonSet `${DAEMONSET_NAME}` in Namespace `${NAMESPACE}`
    [Documentation]    Analyzes logs for repeating patterns, anomalous behavior, and unusual log volume that may indicate underlying issues.
    [Tags]
    ...    logs
    ...    anomalies
    ...    patterns
    ...    volume
    ...    daemonset
    ...    ${DAEMONSET_NAME}
    ...    access:read-only
    ${log_dir}=    RW.K8sLog.Fetch Workload Logs
    ...    workload_type=daemonset
    ...    workload_name=${DAEMONSET_NAME}
    ...    namespace=${NAMESPACE}
    ...    context=${CONTEXT}
    ...    kubeconfig=${kubeconfig}
    ...    log_age=${LOG_AGE}
    
    ${anomaly_results}=    RW.K8sLog.Analyze Log Anomalies
    ...    log_dir=${log_dir}
    ...    workload_type=daemonset
    ...    workload_name=${DAEMONSET_NAME}
    ...    namespace=${NAMESPACE}
    
    # Process anomaly issues
    ${anomaly_issues}=    Evaluate    $anomaly_results.get('issues', [])
    IF    len($anomaly_issues) > 0
        FOR    ${issue}    IN    @{anomaly_issues}
            ${summarized_details}=    RW.K8sLog.Summarize Log Issues    issue_details=${issue["details"]}
            ${next_steps_text}=    Catenate    SEPARATOR=\n    @{issue["next_steps"]}
            
            RW.Core.Add Issue
            ...    severity=${issue["severity"]}
            ...    expected=No log anomalies should be present in DaemonSet `${DAEMONSET_NAME}` in namespace `${NAMESPACE}`
            ...    actual=Log anomalies detected in DaemonSet `${DAEMONSET_NAME}` in namespace `${NAMESPACE}`
            ...    title=${issue["title"]}
            ...    reproduce_hint=Use RW.K8sLog.Analyze Log Anomalies keyword to reproduce this analysis
            ...    details=${summarized_details}
            ...    next_steps=${next_steps_text}
        END
    END
    
    # Add summary to report
    ${anomaly_summary}=    Catenate    SEPARATOR=\n    @{anomaly_results["summary"]}
    RW.Core.Add Pre To Report    Log Anomaly Analysis for DaemonSet ${DAEMONSET_NAME}:\n${anomaly_summary}
    
    RW.K8sLog.Cleanup Temp Files

Check Liveness Probe Configuration for DaemonSet `${DAEMONSET_NAME}`
    [Documentation]    Validates if a Liveness probe has possible misconfigurations
    [Tags]
    ...    liveliness
    ...    probe
    ...    workloads
    ...    errors
    ...    failure
    ...    restart
    ...    get
    ...    daemonset
    ...    ${DAEMONSET_NAME}
    ...    access:read-only
    ${liveness_probe_health}=    RW.CLI.Run Bash File
    ...    bash_file=validate_probes.sh
    ...    cmd_override=./validate_probes.sh livenessProbe | tee "liveness_probe_output"
    ...    env=${env}
    ...    include_in_history=False
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    show_in_rwl_cheatsheet=true
    
    # Check for command failure and create generic issue if needed
    IF    ${liveness_probe_health.returncode} != 0
        RW.Core.Add Issue
        ...    severity=2
        ...    expected=Liveness probe validation should complete for DaemonSet `${DAEMONSET_NAME}` in namespace `${NAMESPACE}`
        ...    actual=Failed to validate liveness probe for DaemonSet `${DAEMONSET_NAME}` in namespace `${NAMESPACE}`
        ...    title=Unable to Validate Liveness Probe for DaemonSet `${DAEMONSET_NAME}`
        ...    reproduce_hint=${liveness_probe_health.cmd}
        ...    details=Validation script failed with exit code ${liveness_probe_health.returncode}:\n\nSTDOUT:\n${liveness_probe_health.stdout}\n\nSTDERR:\n${liveness_probe_health.stderr}
        ...    next_steps=Verify kubeconfig is valid and accessible\nCheck if context '${CONTEXT}' exists and is reachable\nVerify namespace '${NAMESPACE}' exists\nConfirm DaemonSet '${DAEMONSET_NAME}' exists in the namespace\nCheck cluster connectivity and authentication
        ${history}=    RW.CLI.Pop Shell History
        RW.Core.Add Pre To Report    Failed to validate liveness probe:\n\n${liveness_probe_health.stderr}
        RW.Core.Add Pre To Report    Commands Used: ${liveness_probe_health.cmd}
    ELSE
        ${recommendations}=    RW.CLI.Run Cli
        ...    cmd=awk '/Recommended Next Steps:/ {flag=1; next} flag' "liveness_probe_output"
        ...    env=${env}
        ...    include_in_history=false
        IF    len($recommendations.stdout) > 0
            RW.Core.Add Issue
            ...    severity=2
            ...    expected=Liveness probes should be configured and functional for DaemonSet `${DAEMONSET_NAME}` in namespace `${NAMESPACE}`
            ...    actual=Issues found with liveness probe configuration for DaemonSet `${DAEMONSET_NAME}` in namespace `${NAMESPACE}`
            ...    title=Configuration Issues with DaemonSet `${DAEMONSET_NAME}` in namespace `${NAMESPACE}`
            ...    reproduce_hint=View Commands Used in Report Output
            ...    details=Liveness Probe Configuration Issues with DaemonSet ${DAEMONSET_NAME}\n${liveness_probe_health.stdout}
            ...    next_steps=${recommendations.stdout}
        END
        ${history}=    RW.CLI.Pop Shell History
        RW.Core.Add Pre To Report    Liveness probe testing results:\n\n${liveness_probe_health.stdout}
        RW.Core.Add Pre To Report    Commands Used: ${liveness_probe_health.cmd}
    END

Check Readiness Probe Configuration for DaemonSet `${DAEMONSET_NAME}` in Namespace `${NAMESPACE}`
    [Documentation]    Validates if a readiness probe has possible misconfigurations
    [Tags]
    ...    readiness
    ...    probe
    ...    workloads
    ...    errors
    ...    failure
    ...    restart
    ...    get
    ...    daemonset
    ...    ${DAEMONSET_NAME}
    ...    access:read-only
    ${readiness_probe_health}=    RW.CLI.Run Bash File
    ...    bash_file=validate_probes.sh
    ...    cmd_override=./validate_probes.sh readinessProbe | tee "readiness_probe_output"
    ...    env=${env}
    ...    include_in_history=False
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    show_in_rwl_cheatsheet=true
    
    # Check for command failure and create generic issue if needed
    IF    ${readiness_probe_health.returncode} != 0
        RW.Core.Add Issue
        ...    severity=2
        ...    expected=Readiness probe validation should complete for DaemonSet `${DAEMONSET_NAME}` in namespace `${NAMESPACE}`
        ...    actual=Failed to validate readiness probe for DaemonSet `${DAEMONSET_NAME}` in namespace `${NAMESPACE}`
        ...    title=Unable to Validate Readiness Probe for DaemonSet `${DAEMONSET_NAME}`
        ...    reproduce_hint=${readiness_probe_health.cmd}
        ...    details=Validation script failed with exit code ${readiness_probe_health.returncode}:\n\nSTDOUT:\n${readiness_probe_health.stdout}\n\nSTDERR:\n${readiness_probe_health.stderr}
        ...    next_steps=Verify kubeconfig is valid and accessible\nCheck if context '${CONTEXT}' exists and is reachable\nVerify namespace '${NAMESPACE}' exists\nConfirm DaemonSet '${DAEMONSET_NAME}' exists in the namespace\nCheck cluster connectivity and authentication
        ${history}=    RW.CLI.Pop Shell History
        RW.Core.Add Pre To Report    Failed to validate readiness probe:\n\n${readiness_probe_health.stderr}
        RW.Core.Add Pre To Report    Commands Used: ${readiness_probe_health.cmd}
    ELSE
        ${recommendations}=    RW.CLI.Run Cli
        ...    cmd=awk '/Recommended Next Steps:/ {flag=1; next} flag' "readiness_probe_output"
        ...    env=${env}
        ...    include_in_history=false
        IF    len($recommendations.stdout) > 0
            RW.Core.Add Issue
            ...    severity=2
            ...    expected=Readiness probes should be configured and functional for DaemonSet `${DAEMONSET_NAME}` in namespace `${NAMESPACE}`
            ...    actual=Issues found with readiness probe configuration for DaemonSet `${DAEMONSET_NAME}` in namespace `${NAMESPACE}`
            ...    title=Configuration Issues with DaemonSet `${DAEMONSET_NAME}` in namespace `${NAMESPACE}`
            ...    reproduce_hint=View Commands Used in Report Output
            ...    details=Readiness Probe Issues with DaemonSet ${DAEMONSET_NAME}\n${readiness_probe_health.stdout}
            ...    next_steps=${recommendations.stdout}
        END
        ${history}=    RW.CLI.Pop Shell History
        RW.Core.Add Pre To Report    Readiness probe testing results:\n\n${readiness_probe_health.stdout}
        RW.Core.Add Pre To Report    Commands Used: ${readiness_probe_health.cmd}
    END

Inspect DaemonSet Warning Events for `${DAEMONSET_NAME}` in Namespace `${NAMESPACE}`
    [Documentation]    Fetches warning events related to the DaemonSet workload in the namespace and triages any issues found in the events.
    [Tags]    access:read-only  events    workloads    errors    warnings    get    daemonset    ${DAEMONSET_NAME}
    ${events}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get events --context ${CONTEXT} -n ${NAMESPACE} -o json | jq '(now - (60*60)) as $time_limit | [ .items[] | select(.type == "Warning" and (.involvedObject.kind == "DaemonSet" or .involvedObject.kind == "Pod") and (.involvedObject.name | tostring | contains("${DAEMONSET_NAME}")) and (.lastTimestamp // empty | if . then fromdateiso8601 else 0 end) >= $time_limit and .involvedObject.name != null and .involvedObject.name != "" and .involvedObject.name != "Unknown" and .involvedObject.kind != null and .involvedObject.kind != "") | {kind: .involvedObject.kind, name: .involvedObject.name, reason: .reason, message: .message, firstTimestamp: .firstTimestamp, lastTimestamp: .lastTimestamp} ] | group_by([.kind, .name]) | map({kind: .[0].kind, name: .[0].name, count: length, reasons: map(.reason) | unique, messages: map(.message) | unique, firstTimestamp: (map(.firstTimestamp // empty | if . then fromdateiso8601 else 0 end) | sort | .[0] | if . > 0 then todateiso8601 else null end), lastTimestamp: (map(.lastTimestamp // empty | if . then fromdateiso8601 else 0 end) | sort | reverse | .[0] | if . > 0 then todateiso8601 else null end)})'
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    show_in_rwl_cheatsheet=true
    ...    render_in_commandlist=true
    
    # Check for command failure and create generic issue if needed
    IF    ${events.returncode} != 0
        RW.Core.Add Issue
        ...    severity=2
        ...    expected=DaemonSet warning events should be retrievable for `${DAEMONSET_NAME}` in namespace `${NAMESPACE}`
        ...    actual=Failed to retrieve DaemonSet warning events for `${DAEMONSET_NAME}` in namespace `${NAMESPACE}`
        ...    title=Unable to Fetch Warning Events for DaemonSet `${DAEMONSET_NAME}`
        ...    reproduce_hint=${events.cmd}
        ...    details=Command failed with exit code ${events.returncode}:\n\nSTDOUT:\n${events.stdout}\n\nSTDERR:\n${events.stderr}
        ...    next_steps=Verify kubeconfig is valid and accessible\nCheck if context '${CONTEXT}' exists and is reachable\nVerify namespace '${NAMESPACE}' exists\nConfirm DaemonSet '${DAEMONSET_NAME}' exists in the namespace\nCheck cluster connectivity and authentication
        ${history}=    RW.CLI.Pop Shell History
        RW.Core.Add Pre To Report    Failed to retrieve events:\n\n${events.stderr}
        RW.Core.Add Pre To Report    Commands Used: ${history}
    ELSE
        ${k8s_daemonset_details}=    RW.CLI.Run Cli
        ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get daemonset ${DAEMONSET_NAME} -n ${NAMESPACE} --context ${CONTEXT} -o json
        ...    env=${env}
        ...    secret_file__kubeconfig=${kubeconfig}
        
        # Check for DaemonSet details command failure
        IF    ${k8s_daemonset_details.returncode} != 0
            RW.Core.Add Issue
            ...    severity=2
            ...    expected=DaemonSet details should be retrievable for `${DAEMONSET_NAME}` in namespace `${NAMESPACE}`
            ...    actual=Failed to retrieve DaemonSet details for `${DAEMONSET_NAME}` in namespace `${NAMESPACE}`
            ...    title=Unable to Fetch DaemonSet Details for `${DAEMONSET_NAME}`
            ...    reproduce_hint=${k8s_daemonset_details.cmd}
            ...    details=Command failed with exit code ${k8s_daemonset_details.returncode}:\n\nSTDOUT:\n${k8s_daemonset_details.stdout}\n\nSTDERR:\n${k8s_daemonset_details.stderr}
            ...    next_steps=Verify kubeconfig is valid and accessible\nCheck if context '${CONTEXT}' exists and is reachable\nVerify namespace '${NAMESPACE}' exists\nConfirm DaemonSet '${DAEMONSET_NAME}' exists in the namespace\nCheck cluster connectivity and authentication
            ${history}=    RW.CLI.Pop Shell History
            RW.Core.Add Pre To Report    Failed to retrieve DaemonSet details:\n\n${k8s_daemonset_details.stderr}
            RW.Core.Add Pre To Report    Commands Used: ${history}
        ELSE
            ${related_resource_recommendations}=    RW.K8sHelper.Get Related Resource Recommendations
            ...    k8s_object=${k8s_daemonset_details.stdout}
            
            # Simple JSON parsing with fallback
            TRY
                ${object_list}=    Evaluate    json.loads(r'''${events.stdout}''')    json
            EXCEPT
                Log    Warning: Failed to parse events JSON, creating generic warning issue
                ${object_list}=    Create List
                # Create generic issue if we have events but can't parse them
                IF    "Warning" in $events.stdout
                    RW.Core.Add Issue
                    ...    severity=3
                    ...    expected=No warning events should be present for DaemonSet `${DAEMONSET_NAME}` in namespace `${NAMESPACE}`
                    ...    actual=Warning events detected for DaemonSet `${DAEMONSET_NAME}` in namespace `${NAMESPACE}`
                    ...    title=Warning Events Detected for DaemonSet `${DAEMONSET_NAME}` (Parse Failed)
                    ...    reproduce_hint=${events.cmd}
                    ...    details=Warning events detected but JSON parsing failed. Raw output:\n${events.stdout}
                    ...    next_steps=Manually review events output and investigate warning conditions\n${related_resource_recommendations}
                END
            END
            
            # Consolidate issues by type to avoid duplicates
            ${pod_issues}=    Create List
            ${daemonset_issues}=    Create List
            ${unique_issue_types}=    Create Dictionary
            
            IF    len(@{object_list}) > 0
                FOR    ${item}    IN    @{object_list}
                    ${message_string}=    Catenate    SEPARATOR;    @{item["messages"]}
                    ${messages}=    RW.K8sHelper.Sanitize Messages    ${message_string}
                    ${issues}=    RW.CLI.Run Bash File
                    ...    bash_file=workload_issues.sh
                    ...    cmd_override=./workload_issues.sh "${messages}" "DaemonSet" "${DAEMONSET_NAME}"
                    ...    env=${env}
                    ...    include_in_history=False
                    
                    # Simple JSON parsing with fallback
                    TRY
                        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
                    EXCEPT
                        Log    Warning: Failed to parse workload issues JSON, creating generic issue
                        ${issue_list}=    Create List
                        # Create generic issue if we have content but can't parse it
                        IF    len($messages) > 0
                            ${generic_issue}=    Create Dictionary    
                            ...    severity=3    
                            ...    title=Event Issues for ${item["kind"]} ${item["name"]}    
                            ...    next_steps=Investigate event messages: ${messages}    
                            ...    details=Event detected but issue parsing failed: ${messages}
                            Append To List    ${issue_list}    ${generic_issue}
                        END
                    END
                    
                    # Process issues normally
                    FOR    ${issue}    IN    @{issue_list}
                        ${issue_key}=    Set Variable    ${issue["title"]}
                        ${current_count}=    Evaluate    $unique_issue_types.get("${issue_key}", 0)
                        ${new_count}=    Evaluate    ${current_count} + 1
                        ${updated_dict}=    Evaluate    {**$unique_issue_types, "${issue_key}": ${new_count}}
                        Set Test Variable    ${unique_issue_types}    ${updated_dict}
                        
                        IF    '${item["kind"]}' == 'Pod'
                            Append To List    ${pod_issues}    ${issue}
                        ELSE
                            Append To List    ${daemonset_issues}    ${issue}
                        END
                    END
                END
                
                # Create consolidated issues for pods
                IF    len($pod_issues) > 0
                    ${pod_count}=    Evaluate    len([item for item in $object_list if item['kind'] == 'Pod'])
                    ${sample_pod_issue}=    Set Variable    ${pod_issues[0]}
                    ${all_pod_messages}=    Create List
                    FOR    ${item}    IN    @{object_list}
                        IF    '${item["kind"]}' == 'Pod'
                            ${pod_msg}=    Catenate    **Pod ${item["name"]}**: ${item["messages"][0]}
                            Append To List    ${all_pod_messages}    ${pod_msg}
                        END
                    END
                    ${consolidated_pod_details}=    Catenate    SEPARATOR=\n    @{all_pod_messages}
                    
                    RW.Core.Add Issue
                    ...    severity=${sample_pod_issue["severity"]}
                    ...    expected=Pod readiness and health should be maintained for DaemonSet `${DAEMONSET_NAME}` in namespace `${NAMESPACE}`
                    ...    actual=${pod_count} pods are experiencing issues for DaemonSet `${DAEMONSET_NAME}` in namespace `${NAMESPACE}`
                    ...    title=Multiple Pod Issues for DaemonSet `${DAEMONSET_NAME}`
                    ...    reproduce_hint=${events.cmd}
                    ...    details=**Affected Pods:** ${pod_count}\n\n${consolidated_pod_details}
                    ...    next_steps=${sample_pod_issue["next_steps"]}\n${related_resource_recommendations}
                END
                
                # Create issues for DaemonSet-level problems
                ${processed_daemonset_titles}=    Create Dictionary
                FOR    ${issue}    IN    @{daemonset_issues}
                    ${title_key}=    Set Variable    ${issue["title"]}
                    ${is_duplicate}=    Evaluate    $processed_daemonset_titles.get("${title_key}", False)
                    IF    not ${is_duplicate}
                        ${updated_titles}=    Evaluate    {**$processed_daemonset_titles, "${title_key}": True}
                        Set Test Variable    ${processed_daemonset_titles}    ${updated_titles}
                        RW.Core.Add Issue
                        ...    severity=${issue["severity"]}
                        ...    expected=No DaemonSet-level warning events should be present for DaemonSet `${DAEMONSET_NAME}` in namespace `${NAMESPACE}`
                        ...    actual=DaemonSet-level warning events found for DaemonSet `${DAEMONSET_NAME}` in namespace `${NAMESPACE}`
                        ...    title=${issue["title"]}
                        ...    reproduce_hint=${events.cmd}
                        ...    details=${issue["details"]}
                        ...    next_steps=${issue["next_steps"]}\n${related_resource_recommendations}
                    END
                END
            END
            
            ${history}=    RW.CLI.Pop Shell History
            RW.Core.Add Pre To Report    ${events.stdout}
            RW.Core.Add Pre To Report    Commands Used: ${history}
        END
    END

Fetch DaemonSet Workload Details For `${DAEMONSET_NAME}` in Namespace `${NAMESPACE}`
    [Documentation]    Fetches the current state of the DaemonSet for future review in the report.
    [Tags]    access:read-only  daemonset    details    manifest    info    ${DAEMONSET_NAME}
    ${daemonset}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get daemonset/${DAEMONSET_NAME} --context ${CONTEXT} -n ${NAMESPACE} -o yaml
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    show_in_rwl_cheatsheet=true
    ...    render_in_commandlist=true
    
    # Check for command failure and create generic issue if needed
    IF    ${daemonset.returncode} != 0
        RW.Core.Add Issue
        ...    severity=2
        ...    expected=DaemonSet manifest should be retrievable for `${DAEMONSET_NAME}` in namespace `${NAMESPACE}`
        ...    actual=Failed to retrieve DaemonSet manifest for `${DAEMONSET_NAME}` in namespace `${NAMESPACE}`
        ...    title=Unable to Fetch DaemonSet Manifest for `${DAEMONSET_NAME}`
        ...    reproduce_hint=${daemonset.cmd}
        ...    details=Command failed with exit code ${daemonset.returncode}:\n\nSTDOUT:\n${daemonset.stdout}\n\nSTDERR:\n${daemonset.stderr}
        ...    next_steps=Verify kubeconfig is valid and accessible\nCheck if context '${CONTEXT}' exists and is reachable\nVerify namespace '${NAMESPACE}' exists\nConfirm DaemonSet '${DAEMONSET_NAME}' exists in the namespace\nCheck cluster connectivity and authentication
        ${history}=    RW.CLI.Pop Shell History
        RW.Core.Add Pre To Report    Failed to retrieve DaemonSet manifest:\n\n${daemonset.stderr}
        RW.Core.Add Pre To Report    Commands Used: ${history}
    ELSE
        ${history}=    RW.CLI.Pop Shell History
        RW.Core.Add Pre To Report    Snapshot of DaemonSet state:\n\n${daemonset.stdout}
        RW.Core.Add Pre To Report    Commands Used: ${history}
    END

Inspect DaemonSet Status for `${DAEMONSET_NAME}` in namespace `${NAMESPACE}`
    [Documentation]    Pulls the status information for a given DaemonSet and checks if all pods are properly scheduled and running across nodes, identifying node scheduling issues.
    [Tags]
    ...    daemonset
    ...    status
    ...    nodes
    ...    scheduled
    ...    ready
    ...    unhealthy
    ...    tolerations
    ...    nodeselectors
    ...    ${DAEMONSET_NAME}
    ...    access:read-only
    ${daemonset_status}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get daemonset/${DAEMONSET_NAME} --context ${CONTEXT} -n ${NAMESPACE} -o json | jq '.status | {desired_scheduled: .desiredNumberScheduled, current_scheduled: (.currentNumberScheduled // 0), number_ready: (.numberReady // 0), number_unavailable: (.numberUnavailable // 0), number_misscheduled: (.numberMisscheduled // 0), observed_generation: .observedGeneration}'
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    env=${env}
    ...    show_in_rwl_cheatsheet=true
    ...    render_in_commandlist=true
    
    # Check for command failure and create generic issue if needed
    IF    ${daemonset_status.returncode} != 0
        RW.Core.Add Issue
        ...    severity=2
        ...    expected=DaemonSet status should be retrievable for `${DAEMONSET_NAME}` in namespace `${NAMESPACE}`
        ...    actual=Failed to retrieve DaemonSet status for `${DAEMONSET_NAME}` in namespace `${NAMESPACE}`
        ...    title=Unable to Inspect DaemonSet Status for `${DAEMONSET_NAME}`
        ...    reproduce_hint=${daemonset_status.cmd}
        ...    details=Command failed with exit code ${daemonset_status.returncode}:\n\nSTDOUT:\n${daemonset_status.stdout}\n\nSTDERR:\n${daemonset_status.stderr}
        ...    next_steps=Verify kubeconfig is valid and accessible\nCheck if context '${CONTEXT}' exists and is reachable\nVerify namespace '${NAMESPACE}' exists\nConfirm DaemonSet '${DAEMONSET_NAME}' exists in the namespace\nCheck cluster connectivity and authentication
        ${history}=    RW.CLI.Pop Shell History
        RW.Core.Add Pre To Report    Failed to retrieve DaemonSet status:\n\n${daemonset_status.stderr}
        RW.Core.Add Pre To Report    Commands Used: ${history}
    ELSE
        TRY
            ${ds_status}=    Evaluate    json.loads(r'''${daemonset_status.stdout}''') if r'''${daemonset_status.stdout}'''.strip() else {}    json
        EXCEPT
            Log    Warning: Failed to parse DaemonSet status JSON, using empty status
            ${ds_status}=    Create Dictionary
        END
        
        # Set safe defaults for missing keys
        ${desired_scheduled}=    Evaluate    $ds_status.get('desired_scheduled', 0)
        ${current_scheduled}=    Evaluate    $ds_status.get('current_scheduled', 0)
        ${number_ready}=    Evaluate    $ds_status.get('number_ready', 0)
        ${number_unavailable}=    Evaluate    $ds_status.get('number_unavailable', 0)
        ${number_misscheduled}=    Evaluate    $ds_status.get('number_misscheduled', 0)
        
        IF    ${number_ready} == 0 and ${desired_scheduled} > 0
            ${item_next_steps}=    RW.CLI.Run Bash File
            ...    bash_file=workload_next_steps.sh
            ...    cmd_override=./workload_next_steps.sh "DaemonSet has no ready pods" "DaemonSet" "${DAEMONSET_NAME}"
            ...    env=${env}
            ...    include_in_history=False
            RW.Core.Add Issue
            ...    severity=1
            ...    expected=DaemonSet `${DAEMONSET_NAME}` in namespace `${NAMESPACE}` should have pods scheduled and ready on nodes.
            ...    actual=DaemonSet `${DAEMONSET_NAME}` in namespace `${NAMESPACE}` has no ready pods.
            ...    title=DaemonSet `${DAEMONSET_NAME}` in Namespace `${NAMESPACE}` is unavailable
            ...    reproduce_hint=View Commands Used in Report Output
            ...    details=DaemonSet `${DAEMONSET_NAME}` has ${number_ready} ready pods and needs ${desired_scheduled} scheduled across nodes
            ...    next_steps=${item_next_steps.stdout}
        ELSE IF    ${number_ready} < ${desired_scheduled}
            RW.Core.Add Issue
            ...    severity=3
            ...    expected=DaemonSet `${DAEMONSET_NAME}` in namespace `${NAMESPACE}` should have ${desired_scheduled} ready pods.
            ...    actual=DaemonSet `${DAEMONSET_NAME}` in namespace `${NAMESPACE}` has ${number_ready} ready pods.
            ...    title=DaemonSet `${DAEMONSET_NAME}` has Missing or Unready Pods in Namespace `${NAMESPACE}`
            ...    reproduce_hint=View Commands Used in Report Output
            ...    details=DaemonSet `${DAEMONSET_NAME}` has ${number_ready}/${desired_scheduled} ready pods. Scheduled: ${current_scheduled}, Unavailable: ${number_unavailable}
            ...    next_steps=Check node status and conditions\nVerify DaemonSet tolerations and node selectors\nInvestigate pod events and container restarts\nCheck node resource availability
        ELSE IF    ${number_unavailable} > 0
            RW.Core.Add Issue
            ...    severity=3
            ...    expected=DaemonSet `${DAEMONSET_NAME}` should have no unavailable pods
            ...    actual=DaemonSet `${DAEMONSET_NAME}` has ${number_unavailable} unavailable pods
            ...    title=DaemonSet `${DAEMONSET_NAME}` has Unavailable Pods in Namespace `${NAMESPACE}`
            ...    reproduce_hint=View Commands Used in Report Output
            ...    details=DaemonSet `${DAEMONSET_NAME}` has ${number_unavailable} unavailable pods out of ${desired_scheduled} desired
            ...    next_steps=Check pod status and events\nInvestigate node conditions and taints\nReview DaemonSet tolerations and node selectors
        ELSE IF    ${number_misscheduled} > 0
            RW.Core.Add Issue
            ...    severity=3
            ...    expected=DaemonSet `${DAEMONSET_NAME}` should have no misscheduled pods
            ...    actual=DaemonSet `${DAEMONSET_NAME}` has ${number_misscheduled} misscheduled pods
            ...    title=DaemonSet `${DAEMONSET_NAME}` has Misscheduled Pods in Namespace `${NAMESPACE}`
            ...    reproduce_hint=View Commands Used in Report Output
            ...    details=DaemonSet `${DAEMONSET_NAME}` has ${number_misscheduled} pods running on nodes where they shouldn't
            ...    next_steps=Review DaemonSet node selectors and tolerations\nCheck node labels and taints\nInvestigate pod placement policies
        END
        
        ${history}=    RW.CLI.Pop Shell History
        RW.Core.Add Pre To Report    DaemonSet Status: Ready=${number_ready}/${desired_scheduled}, Unavailable=${number_unavailable}, Misscheduled=${number_misscheduled}
        RW.Core.Add Pre To Report    Commands Used: ${history}
    END

Check Node Affinity and Tolerations for DaemonSet `${DAEMONSET_NAME}` in Namespace `${NAMESPACE}`
    [Documentation]    Checks the node affinity, tolerations, and scheduling constraints of the DaemonSet to identify potential scheduling issues.
    [Tags]
    ...    daemonset
    ...    nodeaffinity
    ...    tolerations
    ...    scheduling
    ...    nodes
    ...    ${DAEMONSET_NAME}
    ...    access:read-only
    ${node_constraints}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get daemonset ${DAEMONSET_NAME} -n ${NAMESPACE} --context ${CONTEXT} -o json | jq '{nodeSelector: .spec.template.spec.nodeSelector, tolerations: .spec.template.spec.tolerations, affinity: .spec.template.spec.affinity}'
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    show_in_rwl_cheatsheet=true
    ...    render_in_commandlist=true
    
    # Check for command failure and create generic issue if needed
    IF    ${node_constraints.returncode} != 0
        RW.Core.Add Issue
        ...    severity=2
        ...    expected=DaemonSet node constraints should be retrievable for `${DAEMONSET_NAME}` in namespace `${NAMESPACE}`
        ...    actual=Failed to retrieve DaemonSet node constraints for `${DAEMONSET_NAME}` in namespace `${NAMESPACE}`
        ...    title=Unable to Check Node Affinity and Tolerations for DaemonSet `${DAEMONSET_NAME}`
        ...    reproduce_hint=${node_constraints.cmd}
        ...    details=Command failed with exit code ${node_constraints.returncode}:\n\nSTDOUT:\n${node_constraints.stdout}\n\nSTDERR:\n${node_constraints.stderr}
        ...    next_steps=Verify kubeconfig is valid and accessible\nCheck if context '${CONTEXT}' exists and is reachable\nVerify namespace '${NAMESPACE}' exists\nCheck cluster connectivity and authentication\nVerify sufficient permissions to view DaemonSets
        ${history}=    RW.CLI.Pop Shell History
        RW.Core.Add Pre To Report    Failed to retrieve node constraints:\n\n${node_constraints.stderr}
        RW.Core.Add Pre To Report    Commands Used: ${history}
    ELSE
        TRY
            ${constraints}=    Evaluate    json.loads(r'''${node_constraints.stdout}''') if r'''${node_constraints.stdout}'''.strip() else {}    json
        EXCEPT
            Log    Warning: Failed to parse node constraints JSON, skipping constraint analysis
            ${constraints}=    Create Dictionary
        END
        
        ${node_selector}=    Evaluate    $constraints.get('nodeSelector') or {}
        ${tolerations}=    Evaluate    $constraints.get('tolerations') or []
        ${affinity}=    Evaluate    $constraints.get('affinity') or {}
        
        # Check if there are restrictive node selectors that might prevent scheduling
        IF    $node_selector and len($node_selector) > 0
            RW.Core.Add Pre To Report    DaemonSet Node Selector: ${node_selector}
        END
        
        IF    $tolerations and len($tolerations) > 0
            RW.Core.Add Pre To Report    DaemonSet Tolerations: ${tolerations}
        ELSE
            # No tolerations might be an issue for DaemonSets that need to run on all nodes
            RW.Core.Add Issue
            ...    severity=4
            ...    expected=DaemonSet `${DAEMONSET_NAME}` should have appropriate tolerations for node scheduling
            ...    actual=DaemonSet `${DAEMONSET_NAME}` has no tolerations configured
            ...    title=DaemonSet `${DAEMONSET_NAME}` Missing Tolerations Configuration
            ...    reproduce_hint=${node_constraints.cmd}
            ...    details=DaemonSet ${DAEMONSET_NAME} has no tolerations, which may prevent it from running on tainted nodes
            ...    next_steps=Review cluster node taints\nAdd appropriate tolerations to DaemonSet if needed\nVerify desired node scheduling behavior
        END
        
        IF    $affinity and len($affinity) > 0
            RW.Core.Add Pre To Report    DaemonSet Affinity Rules: ${affinity}
        END
        
        ${history}=    RW.CLI.Pop Shell History
        RW.Core.Add Pre To Report    Node Constraints:\n${node_constraints.stdout}
        RW.Core.Add Pre To Report    Commands Used: ${history}
    END


*** Keywords ***
Suite Initialization
    ${kubeconfig}=    RW.Core.Import Secret
    ...    kubeconfig
    ...    type=string
    ...    description=The kubernetes kubeconfig yaml containing connection configuration used to connect to cluster(s).
    ...    pattern=\w*
    ...    example=For examples, start here https://kubernetes.io/docs/concepts/configuration/organize-cluster-access-kubeconfig/
    ${KUBERNETES_DISTRIBUTION_BINARY}=    RW.Core.Import User Variable    KUBERNETES_DISTRIBUTION_BINARY
    ...    type=string
    ...    description=Which binary to use for Kubernetes CLI commands.
    ...    pattern=\w*
    ...    enum=[kubectl,oc]
    ...    example=kubectl
    ...    default=kubectl
    ${CONTEXT}=    RW.Core.Import User Variable    CONTEXT
    ...    type=string
    ...    description=Which Kubernetes context to operate within.
    ...    pattern=\w*
    ...    example=my-main-cluster
    ${NAMESPACE}=    RW.Core.Import User Variable    NAMESPACE
    ...    type=string
    ...    description=The name of the Kubernetes namespace to scope actions and searching to.
    ...    pattern=\w*
    ...    example=otel-demo
    ${DAEMONSET_NAME}=    RW.Core.Import User Variable    DAEMONSET_NAME
    ...    type=string
    ...    description=The name of the DaemonSet to triage.
    ...    pattern=\w*
    ...    example=fluentd
    ${LOG_AGE}=    RW.Core.Import User Variable    LOG_AGE
    ...    type=string
    ...    description=The age of logs to fetch from pods, used for log analysis tasks.
    ...    pattern=\w*
    ...    example=1h
    ...    default=3h
    ${LOG_ANALYSIS_DEPTH}=    RW.Core.Import User Variable    LOG_ANALYSIS_DEPTH
    ...    type=string
    ...    description=The depth of log analysis to perform - basic, standard, or comprehensive.
    ...    pattern=\w*
    ...    enum=[basic,standard,comprehensive]
    ...    example=standard
    ...    default=standard
    ${LOG_SEVERITY_THRESHOLD}=    RW.Core.Import User Variable    LOG_SEVERITY_THRESHOLD
    ...    type=string
    ...    description=The minimum severity level for creating issues (1=critical, 2=high, 3=medium, 4=low, 5=info).
    ...    pattern=\d+
    ...    example=3
    ...    default=3
    ${LOG_PATTERN_CATEGORIES_STR}=    RW.Core.Import User Variable    LOG_PATTERN_CATEGORIES
    ...    type=string
    ...    description=Comma-separated list of log pattern categories to scan for.
    ...    pattern=.*
    ...    example=GenericError,AppFailure,StackTrace,Connection
    ...    default=GenericError,AppFailure,StackTrace,Connection,Timeout,Auth,Exceptions,Resource
    ${ANOMALY_THRESHOLD}=    RW.Core.Import User Variable    ANOMALY_THRESHOLD
    ...    type=string
    ...    description=The threshold for detecting event anomalies based on events per minute.
    ...    pattern=\d+
    ...    example=5
    ...    default=5
    
    # Convert comma-separated string to list
    @{LOG_PATTERN_CATEGORIES}=    Split String    ${LOG_PATTERN_CATEGORIES_STR}    ,
    
    Set Suite Variable    ${kubeconfig}
    Set Suite Variable    ${KUBERNETES_DISTRIBUTION_BINARY}
    Set Suite Variable    ${CONTEXT}
    Set Suite Variable    ${NAMESPACE}
    Set Suite Variable    ${DAEMONSET_NAME}
    Set Suite Variable    ${LOG_AGE}
    Set Suite Variable    ${LOG_ANALYSIS_DEPTH}
    Set Suite Variable    ${LOG_SEVERITY_THRESHOLD}
    Set Suite Variable    @{LOG_PATTERN_CATEGORIES}
    Set Suite Variable    ${ANOMALY_THRESHOLD}
    ${env}=    Evaluate    {"KUBECONFIG":"${kubeconfig.key}","KUBERNETES_DISTRIBUTION_BINARY":"${KUBERNETES_DISTRIBUTION_BINARY}","CONTEXT":"${CONTEXT}","NAMESPACE":"${NAMESPACE}","DAEMONSET_NAME":"${DAEMONSET_NAME}"}
    Set Suite Variable    ${env}
