*** Settings ***
Documentation       Triages issues related to a StatefulSet and its pods, including persistent volumes and ordered deployment characteristics.
Metadata            Author    stewartshea
Metadata            Display Name    Kubernetes StatefulSet Triage
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
Library             DateTime

Suite Setup         Suite Initialization


*** Tasks ***
Analyze Application Log Patterns for StatefulSet `${STATEFULSET_NAME}` in Namespace `${NAMESPACE}`
    [Documentation]    Fetches and analyzes logs from the StatefulSet pods for errors, stack traces, connection issues, and other patterns that indicate application health problems.
    [Tags]
    ...    logs
    ...    application
    ...    errors
    ...    patterns
    ...    health
    ...    statefulset
    ...    stacktrace
    ...    access:read-only
    ${log_dir}=    RW.K8sLog.Fetch Workload Logs
    ...    workload_type=statefulset
    ...    workload_name=${STATEFULSET_NAME}
    ...    namespace=${NAMESPACE}
    ...    context=${CONTEXT}
    ...    kubeconfig=${kubeconfig}
    ...    log_age=${LOG_AGE}
    
    ${scan_results}=    RW.K8sLog.Scan Logs For Issues
    ...    log_dir=${log_dir}
    ...    workload_type=statefulset
    ...    workload_name=${STATEFULSET_NAME}
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
            # Use timestamp from log scan results if available, otherwise extract from details
            ${issue_timestamp}=    Evaluate    $issue.get('observed_at', '')
            
            RW.Core.Add Issue
            ...    severity=${severity}
            ...    expected=Application logs should be free of critical errors for statefulset `${STATEFULSET_NAME}` in namespace `${NAMESPACE}`
            ...    actual=${issue.get('title', 'Log pattern issue detected')} in statefulset `${STATEFULSET_NAME}` in namespace `${NAMESPACE}`
            ...    title=${issue.get('title', 'Log Pattern Issue')} in StatefulSet `${STATEFULSET_NAME}`
            ...    reproduce_hint=Check application logs for statefulset `${STATEFULSET_NAME}` in namespace `${NAMESPACE}`
            ...    details=${issue_details_str}
            ...    next_steps=${issue.get('next_steps', 'Review application logs and resolve underlying issues')}
            ...    observed_at=${issue_timestamp}
        END
    END

    ${issues_count}=    Get Length    ${issues}
    
    # Format scan results for better display
    ${formatted_results}=    RW.K8sLog.Format Scan Results For Display    scan_results=${scan_results}
    
    RW.Core.Add Pre To Report    **Log Analysis Summary for StatefulSet `${STATEFULSET_NAME}`**\n**Health Score:** ${log_health_score}\n**Analysis Depth:** ${LOG_ANALYSIS_DEPTH}\n**Categories Analyzed:** ${LOG_PATTERN_CATEGORIES_STR}\n**Issues Found:** ${issues_count}\n\n${formatted_results}
    
    RW.K8sLog.Cleanup Temp Files

Detect Log Anomalies for StatefulSet `${STATEFULSET_NAME}` in Namespace `${NAMESPACE}`
    [Documentation]    Analyzes logs for repeating patterns, anomalous behavior, and unusual log volume that may indicate underlying issues.
    [Tags]
    ...    logs
    ...    anomalies
    ...    patterns
    ...    volume
    ...    statefulset
    ...    ${STATEFULSET_NAME}
    ...    access:read-only
    ${log_dir}=    RW.K8sLog.Fetch Workload Logs
    ...    workload_type=statefulset
    ...    workload_name=${STATEFULSET_NAME}
    ...    namespace=${NAMESPACE}
    ...    context=${CONTEXT}
    ...    kubeconfig=${kubeconfig}
    ...    log_age=${LOG_AGE}
    
    ${anomaly_results}=    RW.K8sLog.Analyze Log Anomalies
    ...    log_dir=${log_dir}
    ...    workload_type=statefulset
    ...    workload_name=${STATEFULSET_NAME}
    ...    namespace=${NAMESPACE}
    
    # Process anomaly issues
    ${anomaly_issues}=    Evaluate    $anomaly_results.get('issues', [])
    IF    len($anomaly_issues) > 0
        FOR    ${issue}    IN    @{anomaly_issues}
            ${summarized_details}=    RW.K8sLog.Summarize Log Issues    issue_details=${issue["details"]}
            ${next_steps_text}=    Catenate    SEPARATOR=\n    @{issue["next_steps"]}
            
            RW.Core.Add Issue
            ...    severity=${issue["severity"]}
            ...    expected=No log anomalies should be present in StatefulSet `${STATEFULSET_NAME}` in namespace `${NAMESPACE}`
            ...    actual=Log anomalies detected in StatefulSet `${STATEFULSET_NAME}` in namespace `${NAMESPACE}`
            ...    title=${issue["title"]}
            ...    reproduce_hint=Use RW.K8sLog.Analyze Log Anomalies keyword to reproduce this analysis
            ...    details=${summarized_details}
            ...    next_steps=${next_steps_text}
            ...    observed_at=${issue["observed_at"]}
        END
    END
    
    # Add summary to report
    ${anomaly_summary}=    Catenate    SEPARATOR=\n    @{anomaly_results["summary"]}
    RW.Core.Add Pre To Report    Log Anomaly Analysis for StatefulSet ${STATEFULSET_NAME}:\n${anomaly_summary}
    
    RW.K8sLog.Cleanup Temp Files

Check Liveness Probe Configuration for StatefulSet `${STATEFULSET_NAME}`
    [Documentation]    Validates if a Liveness probe has possible misconfigurations
    [Tags]
    ...    liveliness
    ...    probe
    ...    workloads
    ...    errors
    ...    failure
    ...    restart
    ...    get
    ...    statefulset
    ...    ${STATEFULSET_NAME}
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
        ${issue_timestamp}=    DateTime.Get Current Date
        RW.Core.Add Issue
        ...    severity=2
        ...    expected=Liveness probe validation should complete for StatefulSet `${STATEFULSET_NAME}` in namespace `${NAMESPACE}`
        ...    actual=Failed to validate liveness probe for StatefulSet `${STATEFULSET_NAME}` in namespace `${NAMESPACE}`
        ...    title=Unable to Validate Liveness Probe for StatefulSet `${STATEFULSET_NAME}`
        ...    reproduce_hint=${liveness_probe_health.cmd}
        ...    details=Validation script failed with exit code ${liveness_probe_health.returncode}:\n\nSTDOUT:\n${liveness_probe_health.stdout}\n\nSTDERR:\n${liveness_probe_health.stderr}
        ...    next_steps=Verify kubeconfig is valid and accessible\nCheck if context '${CONTEXT}' exists and is reachable\nVerify namespace '${NAMESPACE}' exists\nConfirm StatefulSet '${STATEFULSET_NAME}' exists in the namespace\nCheck cluster connectivity and authentication
        ...    observed_at=${issue_timestamp}
        ${history}=    RW.CLI.Pop Shell History
        RW.Core.Add Pre To Report    Failed to validate liveness probe:\n\n${liveness_probe_health.stderr}
        RW.Core.Add Pre To Report    Commands Used: ${liveness_probe_health.cmd}
    ELSE
        ${recommendations}=    RW.CLI.Run Cli
        ...    cmd=awk '/Recommended Next Steps:/ {flag=1; next} flag' "liveness_probe_output"
        ...    env=${env}
        ...    include_in_history=false
        IF    len($recommendations.stdout) > 0
            ${issue_timestamp}=    DateTime.Get Current Date
            RW.Core.Add Issue
            ...    severity=2
            ...    expected=Liveness probes should be configured and functional for StatefulSet `${STATEFULSET_NAME}` in namespace `${NAMESPACE}`
            ...    actual=Issues found with liveness probe configuration for StatefulSet `${STATEFULSET_NAME}` in namespace `${NAMESPACE}`
            ...    title=Configuration Issues with StatefulSet `${STATEFULSET_NAME}` in namespace `${NAMESPACE}`
            ...    reproduce_hint=View Commands Used in Report Output
            ...    details=Liveness Probe Configuration Issues with StatefulSet ${STATEFULSET_NAME}\n${liveness_probe_health.stdout}
            ...    next_steps=${recommendations.stdout}
            ...    observed_at=${issue_timestamp}
        END
        ${history}=    RW.CLI.Pop Shell History
        RW.Core.Add Pre To Report    Liveness probe testing results:\n\n${liveness_probe_health.stdout}
        RW.Core.Add Pre To Report    Commands Used: ${liveness_probe_health.cmd}
    END

Check Readiness Probe Configuration for StatefulSet `${STATEFULSET_NAME}` in Namespace `${NAMESPACE}`
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
    ...    ${STATEFULSET_NAME}
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
        ${issue_timestamp}=    DateTime.Get Current Date
        RW.Core.Add Issue
        ...    severity=2
        ...    expected=Readiness probe validation should complete for StatefulSet `${STATEFULSET_NAME}` in namespace `${NAMESPACE}`
        ...    actual=Failed to validate readiness probe for StatefulSet `${STATEFULSET_NAME}` in namespace `${NAMESPACE}`
        ...    title=Unable to Validate Readiness Probe for StatefulSet `${STATEFULSET_NAME}`
        ...    reproduce_hint=${readiness_probe_health.cmd}
        ...    details=Validation script failed with exit code ${readiness_probe_health.returncode}:\n\nSTDOUT:\n${readiness_probe_health.stdout}\n\nSTDERR:\n${readiness_probe_health.stderr}
        ...    next_steps=Verify kubeconfig is valid and accessible\nCheck if context '${CONTEXT}' exists and is reachable\nVerify namespace '${NAMESPACE}' exists\nConfirm StatefulSet '${STATEFULSET_NAME}' exists in the namespace\nCheck cluster connectivity and authentication
        ...    observed_at=${issue_timestamp}
        ${history}=    RW.CLI.Pop Shell History
        RW.Core.Add Pre To Report    Failed to validate readiness probe:\n\n${readiness_probe_health.stderr}
        RW.Core.Add Pre To Report    Commands Used: ${readiness_probe_health.cmd}
    ELSE
        ${recommendations}=    RW.CLI.Run Cli
        ...    cmd=awk '/Recommended Next Steps:/ {flag=1; next} flag' "readiness_probe_output"
        ...    env=${env}
        ...    include_in_history=false
        IF    len($recommendations.stdout) > 0
            ${issue_timestamp}=    DateTime.Get Current Date
            RW.Core.Add Issue
            ...    severity=2
            ...    expected=Readiness probes should be configured and functional for StatefulSet `${STATEFULSET_NAME}` in namespace `${NAMESPACE}`
            ...    actual=Issues found with readiness probe configuration for StatefulSet `${STATEFULSET_NAME}` in namespace `${NAMESPACE}`
            ...    title=Configuration Issues with StatefulSet `${STATEFULSET_NAME}` in namespace `${NAMESPACE}`
            ...    reproduce_hint=View Commands Used in Report Output
            ...    details=Readiness Probe Issues with StatefulSet ${STATEFULSET_NAME}\n${readiness_probe_health.stdout}
            ...    next_steps=${recommendations.stdout}
            ...    observed_at=${issue_timestamp}
        END
        ${history}=    RW.CLI.Pop Shell History
        RW.Core.Add Pre To Report    Readiness probe testing results:\n\n${readiness_probe_health.stdout}
        RW.Core.Add Pre To Report    Commands Used: ${readiness_probe_health.cmd}
    END

Inspect StatefulSet Warning Events for `${STATEFULSET_NAME}` in Namespace `${NAMESPACE}`
    [Documentation]    Fetches warning events related to the StatefulSet workload in the namespace and triages any issues found in the events.
    [Tags]    access:read-only  events    workloads    errors    warnings    get    statefulset    ${STATEFULSET_NAME}
    ${events}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get events --context ${CONTEXT} -n ${NAMESPACE} -o json | jq '(now - (60*60)) as $time_limit | [ .items[] | select(.type == "Warning" and (.involvedObject.kind == "StatefulSet" or .involvedObject.kind == "Pod" or .involvedObject.kind == "PersistentVolumeClaim") and (.involvedObject.name | tostring | contains("${STATEFULSET_NAME}")) and (.lastTimestamp // empty | if . then fromdateiso8601 else 0 end) >= $time_limit and .involvedObject.name != null and .involvedObject.name != "" and .involvedObject.name != "Unknown" and .involvedObject.kind != null and .involvedObject.kind != "") | {kind: .involvedObject.kind, name: .involvedObject.name, reason: .reason, message: .message, firstTimestamp: .firstTimestamp, lastTimestamp: .lastTimestamp} ] | group_by([.kind, .name]) | map({kind: .[0].kind, name: .[0].name, count: length, reasons: map(.reason) | unique, messages: map(.message) | unique, firstTimestamp: (map(.firstTimestamp // empty | if . then fromdateiso8601 else 0 end) | sort | .[0] | if . > 0 then todateiso8601 else null end), lastTimestamp: (map(.lastTimestamp // empty | if . then fromdateiso8601 else 0 end) | sort | reverse | .[0] | if . > 0 then todateiso8601 else null end)})'
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    show_in_rwl_cheatsheet=true
    ...    render_in_commandlist=true
    
    # Check for command failure and create generic issue if needed
    IF    ${events.returncode} != 0
        ${issue_timestamp}=    DateTime.Get Current Date
        RW.Core.Add Issue
        ...    severity=2
        ...    expected=StatefulSet warning events should be retrievable for `${STATEFULSET_NAME}` in namespace `${NAMESPACE}`
        ...    actual=Failed to retrieve StatefulSet warning events for `${STATEFULSET_NAME}` in namespace `${NAMESPACE}`
        ...    title=Unable to Fetch Warning Events for StatefulSet `${STATEFULSET_NAME}`
        ...    reproduce_hint=${events.cmd}
        ...    details=Command failed with exit code ${events.returncode}:\n\nSTDOUT:\n${events.stdout}\n\nSTDERR:\n${events.stderr}
        ...    next_steps=Verify kubeconfig is valid and accessible\nCheck if context '${CONTEXT}' exists and is reachable\nVerify namespace '${NAMESPACE}' exists\nConfirm StatefulSet '${STATEFULSET_NAME}' exists in the namespace\nCheck cluster connectivity and authentication
        ...    observed_at=${issue_timestamp}
        ${history}=    RW.CLI.Pop Shell History
        RW.Core.Add Pre To Report    Failed to retrieve events:\n\n${events.stderr}
        RW.Core.Add Pre To Report    Commands Used: ${history}
    ELSE
        ${k8s_statefulset_details}=    RW.CLI.Run Cli
        ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get statefulset ${STATEFULSET_NAME} -n ${NAMESPACE} --context ${CONTEXT} -o json
        ...    env=${env}
        ...    secret_file__kubeconfig=${kubeconfig}
        
        # Check for StatefulSet details command failure
        IF    ${k8s_statefulset_details.returncode} != 0
            ${issue_timestamp}=    DateTime.Get Current Date
            RW.Core.Add Issue
            ...    severity=2
            ...    expected=StatefulSet details should be retrievable for `${STATEFULSET_NAME}` in namespace `${NAMESPACE}`
            ...    actual=Failed to retrieve StatefulSet details for `${STATEFULSET_NAME}` in namespace `${NAMESPACE}`
            ...    title=Unable to Fetch StatefulSet Details for `${STATEFULSET_NAME}`
            ...    reproduce_hint=${k8s_statefulset_details.cmd}
            ...    details=Command failed with exit code ${k8s_statefulset_details.returncode}:\n\nSTDOUT:\n${k8s_statefulset_details.stdout}\n\nSTDERR:\n${k8s_statefulset_details.stderr}
            ...    next_steps=Verify kubeconfig is valid and accessible\nCheck if context '${CONTEXT}' exists and is reachable\nVerify namespace '${NAMESPACE}' exists\nConfirm StatefulSet '${STATEFULSET_NAME}' exists in the namespace\nCheck cluster connectivity and authentication
            ...    observed_at=${issue_timestamp}
            ${history}=    RW.CLI.Pop Shell History
            RW.Core.Add Pre To Report    Failed to retrieve StatefulSet details:\n\n${k8s_statefulset_details.stderr}
            RW.Core.Add Pre To Report    Commands Used: ${history}
        ELSE
            ${related_resource_recommendations}=    RW.K8sHelper.Get Related Resource Recommendations
            ...    k8s_object=${k8s_statefulset_details.stdout}
            
            # Simple JSON parsing with fallback
            TRY
                ${object_list}=    Evaluate    json.loads(r'''${events.stdout}''')    json
            EXCEPT
                Log    Warning: Failed to parse events JSON, creating generic warning issue
                ${object_list}=    Create List
                # Create generic issue if we have events but can't parse them
                IF    "Warning" in $events.stdout
                    ${issue_timestamp}=   DateTime.Get Current Date
                    RW.Core.Add Issue
                    ...    severity=3
                    ...    expected=No warning events should be present for StatefulSet `${STATEFULSET_NAME}` in namespace `${NAMESPACE}`
                    ...    actual=Warning events detected for StatefulSet `${STATEFULSET_NAME}` in namespace `${NAMESPACE}`
                    ...    title=Warning Events Detected for StatefulSet `${STATEFULSET_NAME}` (Parse Failed)
                    ...    reproduce_hint=${events.cmd}
                    ...    details=Warning events detected but JSON parsing failed. Raw output:\n${events.stdout}
                    ...    next_steps=Manually review events output and investigate warning conditions\n${related_resource_recommendations}
                    ...    observed_at=${issue_timestamp}
                END
            END
            
            # Consolidate issues by type to avoid duplicates
            ${pod_issues}=    Create List
            ${statefulset_issues}=    Create List
            ${pvc_issues}=    Create List
            ${unique_issue_types}=    Create Dictionary
            
            IF    len(@{object_list}) > 0
                FOR    ${item}    IN    @{object_list}
                    ${message_string}=    Catenate    SEPARATOR;    @{item["messages"]}
                    ${messages}=    RW.K8sHelper.Sanitize Messages    ${message_string}
                    ${event_timestamp}=    Set Variable    ${item["firstTimestamp"]}
                    ${issues}=    RW.CLI.Run Bash File
                    ...    bash_file=workload_issues.sh
                    ...    cmd_override=./workload_issues.sh "${messages}" "StatefulSet" "${STATEFULSET_NAME}" "${event_timestamp}"
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
                        ELSE IF    '${item["kind"]}' == 'PersistentVolumeClaim'
                            Append To List    ${pvc_issues}    ${issue}
                        ELSE
                            Append To List    ${statefulset_issues}    ${issue}
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
                    ...    expected=Pod readiness and health should be maintained for StatefulSet `${STATEFULSET_NAME}` in namespace `${NAMESPACE}`
                    ...    actual=${pod_count} pods are experiencing issues for StatefulSet `${STATEFULSET_NAME}` in namespace `${NAMESPACE}`
                    ...    title=Multiple Pod Issues for StatefulSet `${STATEFULSET_NAME}`
                    ...    reproduce_hint=${events.cmd}
                    ...    details=**Affected Pods:** ${pod_count}\n\n${consolidated_pod_details}
                    ...    next_steps=${sample_pod_issue["next_steps"]}\n${related_resource_recommendations}
                    ...    observed_at=${sample_pod_issue["observed_at"]}
                END
                
                # Create consolidated issues for PVCs
                IF    len($pvc_issues) > 0
                    ${pvc_count}=    Evaluate    len([item for item in $object_list if item['kind'] == 'PersistentVolumeClaim'])
                    ${sample_pvc_issue}=    Set Variable    ${pvc_issues[0]}
                    ${all_pvc_messages}=    Create List
                    FOR    ${item}    IN    @{object_list}
                        IF    '${item["kind"]}' == 'PersistentVolumeClaim'
                            ${pvc_msg}=    Catenate    **PVC ${item["name"]}**: ${item["messages"][0]}
                            Append To List    ${all_pvc_messages}    ${pvc_msg}
                        END
                    END
                    ${consolidated_pvc_details}=    Catenate    SEPARATOR=\n    @{all_pvc_messages}
                    
                    RW.Core.Add Issue
                    ...    severity=${sample_pvc_issue["severity"]}
                    ...    expected=Persistent Volume Claims should be healthy for StatefulSet `${STATEFULSET_NAME}` in namespace `${NAMESPACE}`
                    ...    actual=${pvc_count} PVCs are experiencing issues for StatefulSet `${STATEFULSET_NAME}` in namespace `${NAMESPACE}`
                    ...    title=Persistent Volume Issues for StatefulSet `${STATEFULSET_NAME}`
                    ...    reproduce_hint=${events.cmd}
                    ...    details=**Affected PVCs:** ${pvc_count}\n\n${consolidated_pvc_details}
                    ...    next_steps=${sample_pvc_issue["next_steps"]}\nCheck PV status and storage class configuration\n${related_resource_recommendations}
                    ...    observed_at=${sample_pvc_issue["observed_at"]}
                END
                
                # Create issues for StatefulSet-level problems
                ${processed_statefulset_titles}=    Create Dictionary
                FOR    ${issue}    IN    @{statefulset_issues}
                    ${title_key}=    Set Variable    ${issue["title"]}
                    ${is_duplicate}=    Evaluate    $processed_statefulset_titles.get("${title_key}", False)
                    IF    not ${is_duplicate}
                        ${updated_titles}=    Evaluate    {**$processed_statefulset_titles, "${title_key}": True}
                        Set Test Variable    ${processed_statefulset_titles}    ${updated_titles}
                        RW.Core.Add Issue
                        ...    severity=${issue["severity"]}
                        ...    expected=No StatefulSet-level warning events should be present for StatefulSet `${STATEFULSET_NAME}` in namespace `${NAMESPACE}`
                        ...    actual=StatefulSet-level warning events found for StatefulSet `${STATEFULSET_NAME}` in namespace `${NAMESPACE}`
                        ...    title=${issue["title"]}
                        ...    reproduce_hint=${events.cmd}
                        ...    details=${issue["details"]}
                        ...    next_steps=${issue["next_steps"]}\n${related_resource_recommendations}
                        ...    observed_at=${issue["observed_at"]}
                    END
                END
            END
            
            ${history}=    RW.CLI.Pop Shell History
            RW.Core.Add Pre To Report    ${events.stdout}
            RW.Core.Add Pre To Report    Commands Used: ${history}
        END
    END

Fetch StatefulSet Workload Details For `${STATEFULSET_NAME}` in Namespace `${NAMESPACE}`
    [Documentation]    Fetches the current state of the StatefulSet for future review in the report.
    [Tags]    access:read-only  statefulset    details    manifest    info    ${STATEFULSET_NAME}
    ${statefulset}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get statefulset/${STATEFULSET_NAME} --context ${CONTEXT} -n ${NAMESPACE} -o yaml
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    show_in_rwl_cheatsheet=true
    ...    render_in_commandlist=true
    
    # Check for command failure and create generic issue if needed
    IF    ${statefulset.returncode} != 0
        ${issue_timestamp}=    DateTime.Get Current Date
        RW.Core.Add Issue
        ...    severity=2
        ...    expected=StatefulSet manifest should be retrievable for `${STATEFULSET_NAME}` in namespace `${NAMESPACE}`
        ...    actual=Failed to retrieve StatefulSet manifest for `${STATEFULSET_NAME}` in namespace `${NAMESPACE}`
        ...    title=Unable to Fetch StatefulSet Manifest for `${STATEFULSET_NAME}`
        ...    reproduce_hint=${statefulset.cmd}
        ...    details=Command failed with exit code ${statefulset.returncode}:\n\nSTDOUT:\n${statefulset.stdout}\n\nSTDERR:\n${statefulset.stderr}
        ...    next_steps=Verify kubeconfig is valid and accessible\nCheck if context '${CONTEXT}' exists and is reachable\nVerify namespace '${NAMESPACE}' exists\nConfirm StatefulSet '${STATEFULSET_NAME}' exists in the namespace\nCheck cluster connectivity and authentication
        ...    observed_at=${issue_timestamp}
        ${history}=    RW.CLI.Pop Shell History
        RW.Core.Add Pre To Report    Failed to retrieve StatefulSet manifest:\n\n${statefulset.stderr}
        RW.Core.Add Pre To Report    Commands Used: ${history}
    ELSE
        ${history}=    RW.CLI.Pop Shell History
        RW.Core.Add Pre To Report    Snapshot of StatefulSet state:\n\n${statefulset.stdout}
        RW.Core.Add Pre To Report    Commands Used: ${history}
    END

Inspect StatefulSet Replicas for `${STATEFULSET_NAME}` in namespace `${NAMESPACE}`
    [Documentation]    Pulls the replica information for a given StatefulSet and checks if it's highly available, if the replica counts are the expected / healthy values, and raises issues if it is not progressing and is missing pods. Includes StatefulSet-specific checks for ordered deployment.
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
    ...    ordered
    ...    ${STATEFULSET_NAME}
    ...    access:read-only
    ${statefulset_replicas}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get statefulset/${STATEFULSET_NAME} --context ${CONTEXT} -n ${NAMESPACE} -o json | jq '.status | {desired_replicas: .replicas, ready_replicas: (.readyReplicas // 0), current_replicas: (.currentReplicas // 0), updated_replicas: (.updatedReplicas // 0), observed_generation: .observedGeneration, current_revision: .currentRevision, update_revision: .updateRevision}'
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    env=${env}
    ...    show_in_rwl_cheatsheet=true
    ...    render_in_commandlist=true
    
    # Check for command failure and create generic issue if needed
    IF    ${statefulset_replicas.returncode} != 0
        ${issue_timestamp}=    DateTime.Get Current Date
        RW.Core.Add Issue
        ...    severity=2
        ...    expected=StatefulSet replica status should be retrievable for `${STATEFULSET_NAME}` in namespace `${NAMESPACE}`
        ...    actual=Failed to retrieve StatefulSet replica status for `${STATEFULSET_NAME}` in namespace `${NAMESPACE}`
        ...    title=Unable to Inspect StatefulSet Replicas for `${STATEFULSET_NAME}`
        ...    reproduce_hint=${statefulset_replicas.cmd}
        ...    details=Command failed with exit code ${statefulset_replicas.returncode}:\n\nSTDOUT:\n${statefulset_replicas.stdout}\n\nSTDERR:\n${statefulset_replicas.stderr}
        ...    next_steps=Verify kubeconfig is valid and accessible\nCheck if context '${CONTEXT}' exists and is reachable\nVerify namespace '${NAMESPACE}' exists\nConfirm StatefulSet '${STATEFULSET_NAME}' exists in the namespace\nCheck cluster connectivity and authentication
        ...    observed_at=${issue_timestamp}
        ${history}=    RW.CLI.Pop Shell History
        RW.Core.Add Pre To Report    Failed to retrieve StatefulSet replica status:\n\n${statefulset_replicas.stderr}
        RW.Core.Add Pre To Report    Commands Used: ${history}
    ELSE
        TRY
            ${statefulset_status}=    Evaluate    json.loads(r'''${statefulset_replicas.stdout}''') if r'''${statefulset_replicas.stdout}'''.strip() else {}    json
        EXCEPT
            Log    Warning: Failed to parse StatefulSet status JSON, using empty status
            ${statefulset_status}=    Create Dictionary
        END
        
        # Set safe defaults for missing keys
        ${ready_replicas}=    Evaluate    $statefulset_status.get('ready_replicas', 0)
        ${desired_replicas}=    Evaluate    $statefulset_status.get('desired_replicas', 0)
        ${current_replicas}=    Evaluate    $statefulset_status.get('current_replicas', 0)
        ${updated_replicas}=    Evaluate    $statefulset_status.get('updated_replicas', 0)
        
        IF    ${ready_replicas} == 0 and ${desired_replicas} > 0
            ${item_next_steps}=    RW.CLI.Run Bash File
            ...    bash_file=workload_next_steps.sh
            ...    cmd_override=./workload_next_steps.sh "StatefulSet has no ready replicas" "StatefulSet" "${STATEFULSET_NAME}"
            ...    env=${env}
            ...    include_in_history=False
            ${issue_timestamp}=    DateTime.Get Current Date
            RW.Core.Add Issue
            ...    severity=1
            ...    expected=StatefulSet `${STATEFULSET_NAME}` in namespace `${NAMESPACE}` should have minimum availability / pod.
            ...    actual=StatefulSet `${STATEFULSET_NAME}` in namespace `${NAMESPACE}` does not have minimum availability / pods.
            ...    title=StatefulSet `${STATEFULSET_NAME}` in Namespace `${NAMESPACE}` is unavailable
            ...    reproduce_hint=View Commands Used in Report Output
            ...    details=StatefulSet `${STATEFULSET_NAME}` has ${ready_replicas} ready pods and needs ${desired_replicas}
            ...    next_steps=${item_next_steps.stdout}
            ...    observed_at=${issue_timestamp}
        ELSE IF    ${ready_replicas} < ${desired_replicas}
            ${issue_timestamp}=    DateTime.Get Current Date
            RW.Core.Add Issue
            ...    severity=3
            ...    expected=StatefulSet `${STATEFULSET_NAME}` in namespace `${NAMESPACE}` should have ${desired_replicas} pods.
            ...    actual=StatefulSet `${STATEFULSET_NAME}` in namespace `${NAMESPACE}` has ${ready_replicas} ready pods.
            ...    title=StatefulSet `${STATEFULSET_NAME}` has Missing Replicas in Namespace `${NAMESPACE}`
            ...    reproduce_hint=View Commands Used in Report Output
            ...    details=StatefulSet `${STATEFULSET_NAME}` has ${ready_replicas}/${desired_replicas} ready pods. Current: ${current_replicas}, Updated: ${updated_replicas}
            ...    next_steps=Check pod status and investigate why replicas are not ready\nVerify persistent volume claims are bound\nCheck storage class configuration\nInvestigate ordered pod startup issues
            ...    observed_at=${issue_timestamp}
        ELSE IF    ${updated_replicas} < ${current_replicas}
            ${issue_timestamp}=    DateTime.Get Current Date
            RW.Core.Add Issue
            ...    severity=3
            ...    expected=StatefulSet `${STATEFULSET_NAME}` should have all replicas updated to the latest revision
            ...    actual=StatefulSet `${STATEFULSET_NAME}` has ${updated_replicas}/${current_replicas} replicas updated
            ...    title=StatefulSet `${STATEFULSET_NAME}` Update In Progress in Namespace `${NAMESPACE}`
            ...    reproduce_hint=View Commands Used in Report Output
            ...    details=StatefulSet `${STATEFULSET_NAME}` rolling update is in progress: ${updated_replicas}/${current_replicas} pods updated
            ...    next_steps=Monitor rolling update progress\nCheck for pod startup issues\nVerify persistent volume availability
            ...    observed_at=${issue_timestamp}
        END
    END

Check StatefulSet PersistentVolumeClaims for `${STATEFULSET_NAME}` in Namespace `${NAMESPACE}`
    [Documentation]    Checks the status of PersistentVolumeClaims associated with the StatefulSet and identifies storage-related issues.
    [Tags]
    ...    statefulset
    ...    pvc
    ...    persistent
    ...    volume
    ...    storage
    ...    ${STATEFULSET_NAME}
    ...    access:read-only
    ${pvcs}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get pvc --context ${CONTEXT} -n ${NAMESPACE} -o json | jq '.items[] | select(.metadata.labels."app.kubernetes.io/name" // .metadata.name | test("${STATEFULSET_NAME}")) | {name: .metadata.name, status: .status.phase, capacity: .status.capacity.storage, storageClass: .spec.storageClassName, volumeName: .spec.volumeName}'
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    show_in_rwl_cheatsheet=true
    ...    render_in_commandlist=true
    
    # Check for command failure and create generic issue if needed
    IF    ${pvcs.returncode} != 0
        ${issue_timestamp}=    DateTime.Get Current Date
        RW.Core.Add Issue
        ...    severity=2
        ...    expected=PersistentVolumeClaim status should be retrievable for StatefulSet `${STATEFULSET_NAME}` in namespace `${NAMESPACE}`
        ...    actual=Failed to retrieve PersistentVolumeClaim status for StatefulSet `${STATEFULSET_NAME}` in namespace `${NAMESPACE}`
        ...    title=Unable to Check StatefulSet PersistentVolumeClaims for `${STATEFULSET_NAME}`
        ...    reproduce_hint=${pvcs.cmd}
        ...    details=Command failed with exit code ${pvcs.returncode}:\n\nSTDOUT:\n${pvcs.stdout}\n\nSTDERR:\n${pvcs.stderr}
        ...    next_steps=Verify kubeconfig is valid and accessible\nCheck if context '${CONTEXT}' exists and is reachable\nVerify namespace '${NAMESPACE}' exists\nCheck cluster connectivity and authentication\nVerify sufficient permissions to view PVCs
        ...    observed_at=${issue_timestamp}
        ${history}=    RW.CLI.Pop Shell History
        RW.Core.Add Pre To Report    Failed to retrieve PVC status:\n\n${pvcs.stderr}
        RW.Core.Add Pre To Report    Commands Used: ${history}
    ELSE
        TRY
            ${pvc_list}=    Evaluate    json.loads(r'''[${pvcs.stdout}]''') if r'''${pvcs.stdout}'''.strip() else []    json
        EXCEPT
            Log    Warning: Failed to parse PVC JSON, skipping PVC analysis
            ${pvc_list}=    Create List
        END
        
        ${pvc_issues}=    Create List
        ${bound_pvcs}=    Set Variable    0
        ${total_pvcs}=    Evaluate    len($pvc_list)
        
        FOR    ${pvc}    IN    @{pvc_list}
            IF    "${pvc['status']}" == "Bound"
                ${bound_pvcs}=    Evaluate    ${bound_pvcs} + 1
            ELSE
                ${pvc_issue}=    Create Dictionary
                ...    name=${pvc["name"]}
                ...    status=${pvc["status"]}
                ...    storage_class=${pvc.get("storageClass", "default")}
                Append To List    ${pvc_issues}    ${pvc_issue}
            END
        END
        
        IF    len($pvc_issues) > 0
            ${unbound_details}=    Create List
            FOR    ${issue}    IN    @{pvc_issues}
                ${detail}=    Catenate    **PVC ${issue["name"]}**: Status=${issue["status"]}, StorageClass=${issue["storage_class"]}
                Append To List    ${unbound_details}    ${detail}
            END
            ${details_text}=    Catenate    SEPARATOR=\n    @{unbound_details}
            ${issue_timestamp}=    DateTime.Get Current Date

            RW.Core.Add Issue
            ...    severity=2
            ...    expected=All PersistentVolumeClaims for StatefulSet `${STATEFULSET_NAME}` should be bound in namespace `${NAMESPACE}`
            ...    actual=${len($pvc_issues)} PersistentVolumeClaims are not bound for StatefulSet `${STATEFULSET_NAME}` in namespace `${NAMESPACE}`
            ...    title=Unbound PersistentVolumeClaims for StatefulSet `${STATEFULSET_NAME}`
            ...    reproduce_hint=${pvcs.cmd}
            ...    details=**Unbound PVCs:** ${len($pvc_issues)}/${total_pvcs}\n\n${details_text}
            ...    next_steps=Check storage class availability\nVerify persistent volume provisioner is working\nCheck node storage capacity\nInvestigate storage class permissions
            ...    observed_at=${issue_timestamp}
        END
        
        RW.Core.Add Pre To Report    StatefulSet PVC Status: ${bound_pvcs}/${total_pvcs} bound
        RW.Core.Add Pre To Report    PVC Details:\n${pvcs.stdout}
        ${history}=    RW.CLI.Pop Shell History
        RW.Core.Add Pre To Report    Commands Used: ${history}
    END

Identify Recent Configuration Changes for StatefulSet `${STATEFULSET_NAME}` in Namespace `${NAMESPACE}`
    [Documentation]    Identifies recent configuration changes from ControllerRevision analysis that might be related to current issues.
    [Tags]
    ...    configuration
    ...    changes
    ...    tracking
    ...    controllerrevision
    ...    statefulset
    ...    analysis
    ...    access:read-only
    
    # Run configuration change analysis using bash script (matches other task patterns)
    ${config_analysis}=    RW.CLI.Run Cli
    ...    cmd=bash track_statefulset_config_changes.sh "${STATEFULSET_NAME}" "${NAMESPACE}" "${CONTEXT}" "24h"
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    
    # Add the full analysis output to the report
    RW.Core.Add Pre To Report    **Configuration Change Analysis for StatefulSet `${STATEFULSET_NAME}`**\n\n```\n${config_analysis.stdout}\n```
    
    # Parse output for specific patterns and create issues if needed
    ${output}=    Set Variable    ${config_analysis.stdout}
    ${lines}=    Split String    ${output}    \n
    ${change_time}=    Set Variable    Unknown

    # Extract timestamp (everything between "(created: " and ",")
    FOR    ${line}    IN    @{lines}
        IF    "(created: " in $line
            ${time_part}=    Evaluate    "${line}".split("(created: ")[1] if len("${line}".split("(created: ")) > 1 else "Unknown"
            ${change_time}=    Evaluate    "${time_part}".split(",")[0] if "," in "${time_part}" else "${time_part}".split(")")[0] if ")" in "${time_part}" else "${time_part}"
        END
    END
    
    # Check for recent ControllerRevision changes
    IF    "Recent ControllerRevision change detected" in $output
        # Extract ControllerRevision information for issue creation
        ${lines}=    Split String    ${output}    \n
        ${current_revision}=    Set Variable    Unknown
        
        FOR    ${line}    IN    @{lines}
            IF    "Current ControllerRevision:" in $line
                # Extract ControllerRevision name (everything between "Current ControllerRevision: " and " (created:")
                ${rev_part}=    Evaluate    "${line}".split("Current ControllerRevision: ")[1] if len("${line}".split("Current ControllerRevision: ")) > 1 else "Unknown"
                ${current_revision}=    Evaluate    "${rev_part}".split(" (created:")[0] if " (created:" in "${rev_part}" else "${rev_part}"
            END
        END
        
        # Check for CRITICAL volume claim template changes
        IF    "Volume Claim Template Changes Detected" in $output
            # Extract volume template change details from output
            ${volume_details}=    Set Variable    ${EMPTY}
            ${in_volume_section}=    Set Variable    ${False}
            FOR    ${line}    IN    @{lines}
                IF    "Volume Claim Template Changes Detected!" in $line
                    ${in_volume_section}=    Set Variable    ${True}
                ELSE IF    ${in_volume_section}
                    IF    "Previous volume claim templates:" in $line or "Current volume claim templates:" in $line or $line.strip().startswith("- ")
                        # Clean up emojis and format for issue details
                        ${clean_line}=    Evaluate    "${line}".replace("🚨", "").replace("⚠️", "").strip()
                        ${volume_details}=    Set Variable    ${volume_details}${clean_line}\n
                    ELSE IF    $line.strip() == ""
                        ${in_volume_section}=    Set Variable    ${False}
                    END
                END
            END
            
            RW.Core.Add Issue
            ...    severity=2
            ...    expected=Volume claim templates should be stable for StatefulSet `${STATEFULSET_NAME}` in namespace `${NAMESPACE}`
            ...    actual=Volume claim template was modified recently for StatefulSet `${STATEFULSET_NAME}` in namespace `${NAMESPACE}`
            ...    title=CRITICAL: Volume Claim Template Changes Detected for StatefulSet `${STATEFULSET_NAME}`
            ...    reproduce_hint=Check ControllerRevision history for StatefulSet `${STATEFULSET_NAME}` in namespace `${NAMESPACE}`
            ...    details=CRITICAL CONFIGURATION CHANGE DETECTED\n\nChange Type: Volume Claim Template Update\nTimestamp: ${change_time}\nCurrent Revision: ${current_revision}\n\nWARNING: This is a critical change for StatefulSets that can affect data persistence!\n\nVolume Template Changes:\n${volume_details}\nThis change requires immediate attention as it affects persistent storage for the StatefulSet.
            ...    next_steps=CRITICAL: Volume template changes require immediate attention\nVerify persistent volume compatibility\nCheck for data migration requirements\nEnsure backup procedures are in place\nMonitor pod startup and volume attachment\nValidate data integrity after changes
            ...    observed_at=${change_time}
        END
        
        # Check for container image changes
        IF    "Container Image Changes Detected" in $output
            # Extract image change details from output
            ${image_details}=    Set Variable    ${EMPTY}
            ${in_image_section}=    Set Variable    ${False}
            FOR    ${line}    IN    @{lines}
                IF    "Container Image Changes Detected:" in $line
                    ${in_image_section}=    Set Variable    ${True}
                ELSE IF    ${in_image_section}
                    IF    "Previous images:" in $line or "Current images:" in $line or $line.strip().startswith("- ")
                        ${image_details}=    Set Variable    ${image_details}${line}\n
                    ELSE IF    $line.strip() == ""
                        ${in_image_section}=    Set Variable    ${False}
                    END
                END
            END
            
            RW.Core.Add Issue
            ...    severity=3
            ...    expected=Container images should be stable for StatefulSet `${STATEFULSET_NAME}` in namespace `${NAMESPACE}`
            ...    actual=Container image was updated recently for StatefulSet `${STATEFULSET_NAME}` in namespace `${NAMESPACE}`
            ...    title=Recent Container Image Update Detected for StatefulSet `${STATEFULSET_NAME}`
            ...    reproduce_hint=Check ControllerRevision history for StatefulSet `${STATEFULSET_NAME}` in namespace `${NAMESPACE}`
            ...    details=Configuration Change Detected\n\nChange Type: Container Image Update\nTimestamp: ${change_time}\nCurrent Revision: ${current_revision}\n\nImage Changes:\n${image_details}\nThis change may be related to current StatefulSet issues. Verify the image update was intentional and check for known issues with the new image version.
            ...    next_steps=Verify the image update was intentional\nCheck if the new image version has known issues\nReview StatefulSet rolling update status\nMonitor ordered pod updates (StatefulSets update sequentially)
            ...    observed_at=${change_time}
        END
        
        # Check for environment variable changes
        IF    "Environment Variable Changes Detected" in $output
            # Extract environment variable change details from output
            ${env_details}=    Set Variable    ${EMPTY}
            ${in_env_section}=    Set Variable    ${False}
            FOR    ${line}    IN    @{lines}
                IF    "Environment Variable Changes Detected:" in $line
                    ${in_env_section}=    Set Variable    ${True}
                ELSE IF    ${in_env_section}
                    ${line_stripped}=    Evaluate    "${line}".strip()
                    ${is_indented}=    Evaluate    len("${line}") > len("${line_stripped}") and "${line}".startswith(" ")
                    IF    "Added variables:" in $line or "Removed variables:" in $line or "Modified variables:" in $line or "Summary:" in $line or ${is_indented}
                        # Clean up emojis and format for issue details
                        ${clean_line}=    Evaluate    "${line}".replace("➕", "").replace("➖", "").replace("🔄", "").replace("📊", "").strip()
                        ${env_details}=    Set Variable    ${env_details}${clean_line}\n
                    ELSE IF    $line.strip() == ""
                        ${in_env_section}=    Set Variable    ${False}
                    END
                END
            END
            
            RW.Core.Add Issue
            ...    severity=4
            ...    expected=Environment configuration should be stable for StatefulSet `${STATEFULSET_NAME}` in namespace `${NAMESPACE}`
            ...    actual=Environment variables were modified recently for StatefulSet `${STATEFULSET_NAME}` in namespace `${NAMESPACE}`
            ...    title=Recent Environment Configuration Changes Detected for StatefulSet `${STATEFULSET_NAME}`
            ...    reproduce_hint=Check ControllerRevision history for StatefulSet `${STATEFULSET_NAME}` in namespace `${NAMESPACE}`
            ...    details=Configuration Change Detected\n\nChange Type: Environment Variables Update\nTimestamp: ${change_time}\nCurrent Revision: ${current_revision}\n\nEnvironment Variable Changes:\n${env_details}\nThese environment variable changes may be related to current StatefulSet issues. Review the changes to ensure they align with expected configuration.
            ...    next_steps=Review recent environment variable changes\nVerify changes align with expected configuration\nCheck application logs for configuration-related errors\nMonitor ordered pod updates (StatefulSets update sequentially)
            ...    observed_at=${change_time}
        END
        
        # Check for resource requirement changes
        IF    "Resource Requirement Changes Detected" in $output
            RW.Core.Add Issue
            ...    severity=4
            ...    expected=Resource limits should be stable for StatefulSet `${STATEFULSET_NAME}` in namespace `${NAMESPACE}`
            ...    actual=Resource limits/requests were modified recently for StatefulSet `${STATEFULSET_NAME}` in namespace `${NAMESPACE}`
            ...    title=Recent Resource Limit Changes Detected for StatefulSet `${STATEFULSET_NAME}`
            ...    reproduce_hint=Check ControllerRevision history for StatefulSet `${STATEFULSET_NAME}` in namespace `${NAMESPACE}`
            ...    details=**Configuration Change Detected**\n\n**Change Type:** Resource Limits/Requests Update\n**Timestamp:** ${change_time}\n**Current Revision:** ${current_revision}\n\nSee full analysis in report for detailed resource comparison.
            ...    next_steps=Monitor resource utilization after changes\nVerify resource limits are appropriate for workload\nCheck for resource constraint issues\nEnsure persistent volume performance is adequate\nMonitor ordered pod updates (StatefulSets update sequentially)
            ...    observed_at=${change_time}
        END
    END
    
    # Check for kubectl apply detection
    IF    "Recent kubectl apply detected" in $output
        RW.Core.Add Issue
        ...    severity=4
        ...    expected=StatefulSet configuration should be synchronized for StatefulSet `${STATEFULSET_NAME}` in namespace `${NAMESPACE}`
        ...    actual=Recent kubectl apply operation detected for StatefulSet `${STATEFULSET_NAME}` in namespace `${NAMESPACE}`
        ...    title=Recent kubectl apply Operation Detected for StatefulSet `${STATEFULSET_NAME}`
        ...    reproduce_hint=Check StatefulSet generation vs observed generation for `${STATEFULSET_NAME}` in namespace `${NAMESPACE}`
        ...    details=Recent kubectl apply operation detected. The StatefulSet configuration has been updated but may still be processing.\n\nSee full analysis in report for generation gap details.
        ...    next_steps=Wait for controller to process changes\nCheck StatefulSet status and conditions\nVerify no resource constraints are preventing updates\nMonitor ordered pod updates (StatefulSets update sequentially)
        ...    observed_at=${change_time}
    END
    
    # Check for configuration drift
    IF    "Configuration drift detected" in $output
        RW.Core.Add Issue
        ...    severity=4
        ...    expected=StatefulSet configuration should be synchronized for StatefulSet `${STATEFULSET_NAME}` in namespace `${NAMESPACE}`
        ...    actual=Configuration drift detected for StatefulSet `${STATEFULSET_NAME}` in namespace `${NAMESPACE}`
        ...    title=Configuration Drift Detected for StatefulSet `${STATEFULSET_NAME}`
        ...    reproduce_hint=Check StatefulSet generation vs observed generation for `${STATEFULSET_NAME}` in namespace `${NAMESPACE}`
        ...    details=Configuration drift detected. The StatefulSet has been modified but the controller hasn't processed all changes yet.\n\nSee full analysis in report for drift details.
        ...    next_steps=Wait for controller to process changes\nCheck StatefulSet status and conditions\nVerify no resource constraints are preventing updates\nMonitor ordered pod updates (StatefulSets update sequentially)
        ...    observed_at=${change_time}
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
    ${STATEFULSET_NAME}=    RW.Core.Import User Variable    STATEFULSET_NAME
    ...    type=string
    ...    description=The name of the StatefulSet to triage.
    ...    pattern=\w*
    ...    example=mysql-primary
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
    Set Suite Variable    ${STATEFULSET_NAME}
    Set Suite Variable    ${LOG_AGE}
    Set Suite Variable    ${LOG_ANALYSIS_DEPTH}
    Set Suite Variable    ${LOG_SEVERITY_THRESHOLD}
    Set Suite Variable    @{LOG_PATTERN_CATEGORIES}
    Set Suite Variable    ${ANOMALY_THRESHOLD}
    ${env}=    Evaluate    {"KUBECONFIG":"${kubeconfig.key}","KUBERNETES_DISTRIBUTION_BINARY":"${KUBERNETES_DISTRIBUTION_BINARY}","CONTEXT":"${CONTEXT}","NAMESPACE":"${NAMESPACE}","STATEFULSET_NAME":"${STATEFULSET_NAME}"}
    Set Suite Variable    ${env}
