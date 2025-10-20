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
Library             RW.K8sLog

Library             OperatingSystem
Library             String
Library             Collections

Suite Setup         Suite Initialization


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
    ${DEPLOYMENT_NAME}=    RW.Core.Import User Variable    DEPLOYMENT_NAME
    ...    type=string
    ...    description=The name of the deployment to triage.
    ...    pattern=\w*
    ...    example=otel-demo-frontend
    ${LOG_LINES}=    RW.Core.Import User Variable    LOG_LINES
    ...    type=string
    ...    description=The number of log lines to fetch from the pods when inspecting logs.
    ...    pattern=\d+
    ...    example=100
    ...    default=100
    ${LOG_AGE}=    RW.Core.Import User Variable    LOG_AGE
    ...    type=string
    ...    description=The age of logs to fetch from pods, used for log analysis tasks.
    ...    pattern=\w*
    ...    example=10m
    ...    default=10m

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
    ...    default=GenericError,AppFailure,StackTrace,Connection,Timeout,Auth,Exceptions,Resource,HealthyRecovery
    ${ANOMALY_THRESHOLD}=    RW.Core.Import User Variable    ANOMALY_THRESHOLD
    ...    type=string
    ...    description=The threshold for detecting event anomalies based on events per minute.
    ...    pattern=\d+
    ...    example=5
    ...    default=5
    ${LOGS_ERROR_PATTERN}=    RW.Core.Import User Variable    LOGS_ERROR_PATTERN
    ...    type=string
    ...    description=The error pattern to use when grep-ing logs.
    ...    pattern=\w*
    ...    example=(Error: 13|Error: 14)
    ...    default=error|ERROR
    ${LOGS_EXCLUDE_PATTERN}=    RW.Core.Import User Variable    LOGS_EXCLUDE_PATTERN
    ...    type=string
    ...    description=Pattern used to exclude entries from log analysis when searching for errors. Use regex patterns to filter out false positives like JSON structures.
    ...    pattern=.*
    ...    example="errors":\s*\[\]|"warnings":\s*\[\]
    ...    default="errors":\\s*\\[\\]|\\bINFO\\b|\\bDEBUG\\b|\\bTRACE\\b|\\bSTART\\s*-\\s*|\\bSTART\\s*method\\b
    ${LOG_SCAN_TIMEOUT}=    RW.Core.Import User Variable    LOG_SCAN_TIMEOUT
    ...    type=string
    ...    description=Timeout in seconds for log scanning operations. Increase this value if log scanning times out on large log files.
    ...    pattern=\d+
    ...    example=300
    ...    default=300
    ${EXCLUDED_CONTAINER_NAMES}=    RW.Core.Import User Variable    EXCLUDED_CONTAINER_NAMES
    ...    type=string
    ...    description=Comma-separated list of container names to exclude from log analysis (e.g., linkerd-proxy, istio-proxy, vault-agent).
    ...    pattern=.*
    ...    example=linkerd-proxy,istio-proxy,vault-agent
    ...    default=linkerd-proxy,istio-proxy,vault-agent

    ${CONTAINER_RESTART_AGE}=    RW.Core.Import User Variable    CONTAINER_RESTART_AGE
    ...    type=string
    ...    description=The time window (in (h) hours or (m) minutes) to search for container restarts. Only containers that restarted within this time period will be reported.
    ...    pattern=\w*
    ...    example=10m
    ...    default=10m
    ${CONTAINER_RESTART_THRESHOLD}=    RW.Core.Import User Variable    CONTAINER_RESTART_THRESHOLD
    ...    type=string
    ...    description=The minimum number of restarts required to trigger an issue. Containers with restart counts below this threshold will be ignored.
    ...    pattern=\d+
    ...    example=1
    ...    default=1
    # Convert comma-separated strings to lists
    @{LOG_PATTERN_CATEGORIES}=    Split String    ${LOG_PATTERN_CATEGORIES_STR}    ,
    @{EXCLUDED_CONTAINERS_RAW}=    Run Keyword If    "${EXCLUDED_CONTAINER_NAMES}" != ""    Split String    ${EXCLUDED_CONTAINER_NAMES}    ,    ELSE    Create List
    @{EXCLUDED_CONTAINERS}=    Create List
    FOR    ${container}    IN    @{EXCLUDED_CONTAINERS_RAW}
        ${trimmed_container}=    Strip String    ${container}
        Append To List    ${EXCLUDED_CONTAINERS}    ${trimmed_container}
    END
    
    Set Suite Variable    ${kubeconfig}    ${kubeconfig}
    Set Suite Variable    ${KUBERNETES_DISTRIBUTION_BINARY}
    Set Suite Variable    ${CONTEXT}
    Set Suite Variable    ${NAMESPACE}
    Set Suite Variable    ${DEPLOYMENT_NAME}
    Set Suite Variable    ${LOG_LINES}
    Set Suite Variable    ${LOG_AGE}

    Set Suite Variable    ${LOG_ANALYSIS_DEPTH}
    Set Suite Variable    ${LOG_SEVERITY_THRESHOLD}
    Set Suite Variable    ${LOG_PATTERN_CATEGORIES_STR}
    Set Suite Variable    @{LOG_PATTERN_CATEGORIES}
    Set Suite Variable    ${ANOMALY_THRESHOLD}
    Set Suite Variable    ${LOGS_ERROR_PATTERN}
    Set Suite Variable    ${LOGS_EXCLUDE_PATTERN}
    Set Suite Variable    ${LOG_SCAN_TIMEOUT}
    Set Suite Variable    ${EXCLUDED_CONTAINER_NAMES}
    Set Suite Variable    @{EXCLUDED_CONTAINERS}

    Set Suite Variable    ${CONTAINER_RESTART_AGE}
    Set Suite Variable    ${CONTAINER_RESTART_THRESHOLD}
    # Construct environment dictionary safely to handle special characters in regex patterns
    &{env_dict}=    Create Dictionary    
    ...    KUBECONFIG=${kubeconfig.key}
    ...    KUBERNETES_DISTRIBUTION_BINARY=${KUBERNETES_DISTRIBUTION_BINARY}
    ...    CONTEXT=${CONTEXT}
    ...    NAMESPACE=${NAMESPACE}
    ...    LOGS_ERROR_PATTERN=${LOGS_ERROR_PATTERN}
    ...    LOGS_EXCLUDE_PATTERN=${LOGS_EXCLUDE_PATTERN}
    ...    ANOMALY_THRESHOLD=${ANOMALY_THRESHOLD}
    ...    DEPLOYMENT_NAME=${DEPLOYMENT_NAME}
    ...    CONTAINER_RESTART_AGE=${CONTAINER_RESTART_AGE}
    ...    CONTAINER_RESTART_THRESHOLD=${CONTAINER_RESTART_THRESHOLD}
    ...    LOG_SCAN_TIMEOUT=${LOG_SCAN_TIMEOUT}
    Set Suite Variable    ${env}    ${env_dict}
    
    # Check if deployment is scaled to 0 and handle appropriately
    ${scale_check}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get deployment/${DEPLOYMENT_NAME} --context ${CONTEXT} -n ${NAMESPACE} -o json | jq '{spec_replicas: .spec.replicas, ready_replicas: (.status.readyReplicas // 0), available_condition: (.status.conditions[] | select(.type == "Available") | .status // "Unknown")}'
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    timeout_seconds=30
    
    TRY
        ${scale_status}=    Evaluate    json.loads(r'''${scale_check.stdout}''') if r'''${scale_check.stdout}'''.strip() else {}    json
        ${spec_replicas}=    Evaluate    $scale_status.get('spec_replicas', 1)
        
        IF    ${spec_replicas} == 0
            RW.Core.Add Issue
            ...    severity=4
            ...    expected=Deployment `${DEPLOYMENT_NAME}` operational status documented
            ...    actual=Deployment `${DEPLOYMENT_NAME}` is intentionally scaled to zero replicas
            ...    title=Deployment `${DEPLOYMENT_NAME}` is Scaled Down (Informational)
            ...    reproduce_hint=kubectl get deployment/${DEPLOYMENT_NAME} --context ${CONTEXT} -n ${NAMESPACE} -o yaml
            ...    details=Deployment `${DEPLOYMENT_NAME}` is currently scaled to 0 replicas (spec.replicas=0). This is an intentional configuration and not an error. All pod-related healthchecks have been skipped for efficiency. If the deployment should be running, scale it up using:\nkubectl scale deployment/${DEPLOYMENT_NAME} --replicas=<desired_count> --context ${CONTEXT} -n ${NAMESPACE}
            ...    next_steps=This is informational only. If the deployment should be running, scale it up.
            
            RW.Core.Add Pre To Report    **ℹ️ Deployment `${DEPLOYMENT_NAME}` is scaled to 0 replicas - Skipping pod-related checks**\n**Available Condition:** ${scale_status.get('available_condition', 'Unknown')}
            
            Set Suite Variable    ${SKIP_POD_CHECKS}    ${True}
        ELSE
            Set Suite Variable    ${SKIP_POD_CHECKS}    ${False}
        END
        
    EXCEPT
        Log    Warning: Failed to check deployment scale, continuing with normal checks
        Set Suite Variable    ${SKIP_POD_CHECKS}    ${False}
    END


*** Tasks ***

Analyze Application Log Patterns for Deployment `${DEPLOYMENT_NAME}` in Namespace `${NAMESPACE}`
    [Documentation]    Fetches and analyzes logs from the deployment pods for errors, stack traces, connection issues, and other patterns that indicate application health problems. Note: Warning messages about missing log files for excluded containers (like linkerd-proxy, istio-proxy) are expected and harmless.
    [Tags]
    ...    logs
    ...    application
    ...    errors
    ...    patterns
    ...    health
    ...    deployment
    ...    stacktrace
    ...    access:read-only
    # Skip pod-related checks if deployment is scaled to 0
    IF    not ${SKIP_POD_CHECKS}
        # Temporarily suppress log warnings for excluded containers (they're expected)
        TRY
            ${log_dir}=    RW.K8sLog.Fetch Workload Logs
            ...    workload_type=deployment
            ...    workload_name=${DEPLOYMENT_NAME}
            ...    namespace=${NAMESPACE}
            ...    context=${CONTEXT}
            ...    kubeconfig=${kubeconfig}
            ...    log_age=${LOG_AGE}
            ...    excluded_containers=${EXCLUDED_CONTAINERS}
        EXCEPT    AS    ${log_error}
            # If log fetching fails completely, log the error but continue
            Log    Warning: Log fetching encountered an error: ${log_error}
            # Set empty log directory to continue with other checks
            ${log_dir}=    Set Variable    ${EMPTY}
        END
        
        # Only scan logs if we have a valid log directory
        IF    '''${log_dir}''' != '''${EMPTY}'''
            ${scan_results}=    RW.K8sLog.Scan Logs For Issues
            ...    log_dir=${log_dir}
            ...    workload_type=deployment
            ...    workload_name=${DEPLOYMENT_NAME}
            ...    namespace=${NAMESPACE}
            ...    categories=@{LOG_PATTERN_CATEGORIES}
            ...    custom_patterns_file=runbook_patterns.json
            ...    excluded_containers=${EXCLUDED_CONTAINERS}
        ELSE
            # Create empty scan results if no logs were fetched
            ${scan_results}=    Evaluate    {"issues": [], "summary": ["No logs available for analysis"]}
        END
        
        # Post-process results to filter out patterns matching LOGS_EXCLUDE_PATTERN
        TRY
            IF    $LOGS_EXCLUDE_PATTERN != ""
                ${filtered_issues}=    Evaluate    [issue for issue in $scan_results.get('issues', []) if not __import__('re').search('${LOGS_EXCLUDE_PATTERN}', issue.get('details', ''), __import__('re').IGNORECASE)]    modules=re
                ${filtered_results}=    Evaluate    {**$scan_results, 'issues': $filtered_issues}
                Set Test Variable    ${scan_results}    ${filtered_results}
            END
        EXCEPT
            Log    Warning: Failed to apply LOGS_EXCLUDE_PATTERN filter, using unfiltered results
        END
        
        ${log_health_score}=    RW.K8sLog.Calculate Log Health Score    scan_results=${scan_results}
        
        # Process each issue found in the logs
        ${issues}=    Evaluate    $scan_results.get('issues', [])
        FOR    ${issue}    IN    @{issues}
            ${severity}=    Evaluate    $issue.get('severity', ${LOG_SEVERITY_THRESHOLD})
            IF    ${severity} <= ${LOG_SEVERITY_THRESHOLD}
                # Convert issue details to string to avoid serialization issues
                ${issue_details_raw}=    Evaluate    $issue.get("details", "")
                ${issue_details_str}=    Convert To String    ${issue_details_raw}
                ${summarized_details}=    RW.K8sLog.Summarize Log Issues    issue_details=${issue_details_str}
                
                # Safely extract title and next_steps as strings
                ${issue_title_raw}=    Evaluate    $issue.get('title', 'Log pattern issue detected')
                ${issue_title}=    Convert To String    ${issue_title_raw}
                ${next_steps_raw}=    Evaluate    $issue.get('next_steps', 'Review application logs and resolve underlying issues')
                ${next_steps}=    Convert To String    ${next_steps_raw}
                
                RW.Core.Add Issue
                ...    severity=${severity}
                ...    expected=Application logs should be free of critical errors for deployment `${DEPLOYMENT_NAME}` in namespace `${NAMESPACE}`
                ...    actual=${issue_title} in deployment `${DEPLOYMENT_NAME}` in namespace `${NAMESPACE}`
                ...    title=${issue_title} in Deployment `${DEPLOYMENT_NAME}`
                ...    reproduce_hint=Check application logs for deployment `${DEPLOYMENT_NAME}` in namespace `${NAMESPACE}`
                ...    details=${summarized_details}
                ...    next_steps=${next_steps}
            END
        END

        ${issues_count}=    Get Length    ${issues}
        
        # Convert scan_results to string to avoid serialization issues, then format for display
        ${scan_results_str}=    Evaluate    json.dumps($scan_results, indent=2)    json
        ${formatted_results}=    RW.K8sLog.Format Scan Results For Display    scan_results=${scan_results_str}
        
        RW.Core.Add Pre To Report    **Log Analysis Summary for Deployment `${DEPLOYMENT_NAME}`**\n**Health Score:** ${log_health_score}\n**Analysis Depth:** ${LOG_ANALYSIS_DEPTH}\n**Categories Analyzed:** ${LOG_PATTERN_CATEGORIES_STR}\n**Issues Found:** ${issues_count}\n\n${formatted_results}
        
        RW.K8sLog.Cleanup Temp Files
    END

Detect Log Anomalies for Deployment `${DEPLOYMENT_NAME}` in Namespace `${NAMESPACE}`
    [Documentation]    Analyzes log patterns to identify anomalies such as sudden spikes in error rates, unusual patterns, or recurring issues that might indicate underlying problems.
    [Tags]
    ...    logs
    ...    anomaly
    ...    patterns
    ...    trends
    ...    deployment
    ...    monitoring
    ...    access:read-only
    # Skip pod-related checks if deployment is scaled to 0
    IF    not ${SKIP_POD_CHECKS}
        ${anomaly_results}=    RW.CLI.Run Bash File
        ...    bash_file=event_anomalies.sh
        ...    env=${env}
        ...    secret_file__kubeconfig=${kubeconfig}
        ...    include_in_history=false
        
        IF    ${anomaly_results.returncode} != 0
            RW.Core.Add Issue
            ...    severity=3
            ...    expected=Log anomaly detection should complete successfully for deployment `${DEPLOYMENT_NAME}` in namespace `${NAMESPACE}`
            ...    actual=Failed to analyze log anomalies for deployment `${DEPLOYMENT_NAME}` in namespace `${NAMESPACE}`
            ...    title=Log Anomaly Detection Failed for Deployment `${DEPLOYMENT_NAME}`
            ...    reproduce_hint=${anomaly_results.cmd}
            ...    details=Anomaly detection failed with exit code ${anomaly_results.returncode}:\n\nSTDOUT:\n${anomaly_results.stdout}\n\nSTDERR:\n${anomaly_results.stderr}
            ...    next_steps=Verify log collection is working properly\nCheck if pods are accessible and generating logs\nReview anomaly detection thresholds
        ELSE
            TRY
                ${anomaly_data}=    Evaluate    json.loads(r'''${anomaly_results.stdout}''') if r'''${anomaly_results.stdout}'''.strip() else []    json
                # Handle both array format (direct list) and object format (with 'anomalies' key)
                ${anomalies}=    Evaluate    $anomaly_data if isinstance($anomaly_data, list) else $anomaly_data.get('anomalies', [])
                
                ${anomalies_count}=    Get Length    ${anomalies}
                
                # Count normal vs anomalous events
                ${normal_operations_count}=    Set Variable    ${0}
                ${actual_anomalies_count}=    Set Variable    ${0}
                
                FOR    ${item}    IN    @{anomalies}
                    ${is_normal}=    Evaluate    any(reason in ['Created', 'Started', 'Pulled', 'SuccessfulCreate', 'SuccessfulDelete', 'ScalingReplicaSet'] for reason in $item.get('reasons', []))
                    ${events_per_minute}=    Evaluate    $item.get('average_events_per_minute', 0)
                    
                    IF    ${is_normal} or ${events_per_minute} <= ${ANOMALY_THRESHOLD}
                        ${normal_operations_count}=    Evaluate    ${normal_operations_count} + 1
                    ELSE
                        ${actual_anomalies_count}=    Evaluate    ${actual_anomalies_count} + 1
                        # Create issue for actual anomalies
                        ${severity}=    Evaluate    $item.get('severity', 3)
                        RW.Core.Add Issue
                        ...    severity=${severity}
                        ...    expected=Log patterns should be consistent and normal for deployment `${DEPLOYMENT_NAME}` in namespace `${NAMESPACE}`
                        ...    actual=Event anomaly detected: ${item.get('kind', 'Unknown')}/${item.get('name', 'Unknown')} with ${events_per_minute} events/minute in deployment `${DEPLOYMENT_NAME}` in namespace `${NAMESPACE}`
                        ...    title=Event Anomaly: High Event Rate for ${item.get('kind', 'Unknown')} in Deployment `${DEPLOYMENT_NAME}`
                        ...    reproduce_hint=Review events for ${item.get('kind', 'Unknown')}/${item.get('name', 'Unknown')} in deployment `${DEPLOYMENT_NAME}` in namespace `${NAMESPACE}`
                        ...    details=Detected unusually high event rate of ${events_per_minute} events/minute (threshold: ${ANOMALY_THRESHOLD})\n\nReasons: ${item.get('reasons', [])}\n\nSample Messages: ${item.get('messages', [])[:3]}
                        ...    next_steps=Investigate why ${item.get('kind', 'Unknown')}/${item.get('name', 'Unknown')} is generating high event volume\nCheck for resource constraints, misconfigurations, or application issues\nReview the specific event messages for patterns
                    END
                END
                
                # Generate consolidated anomaly report
                ${anomaly_status}=    Set Variable If    ${actual_anomalies_count} == 0    ✅ No significant anomalies detected - All events appear to be normal operations    ⚠️ ${actual_anomalies_count} anomalies detected
                RW.Core.Add Pre To Report    **Log Anomaly Detection Results for Deployment `${DEPLOYMENT_NAME}`**\n**Total Events Analyzed:** ${anomalies_count}\n**Normal Operations:** ${normal_operations_count} | **Actual Anomalies:** ${actual_anomalies_count}\n**Threshold:** ${ANOMALY_THRESHOLD} events/minute\n\n${anomaly_status}
                
            EXCEPT
                RW.Core.Add Pre To Report    **Log Anomaly Detection:** Completed but results parsing failed
            END
        END
    END

Fetch Deployment Logs for `${DEPLOYMENT_NAME}` in Namespace `${NAMESPACE}`
    [Documentation]    Collects logs from all pods in the deployment for manual review and troubleshooting.
    [Tags]
    ...    logs
    ...    collection
    ...    deployment
    ...    troubleshooting
    ...    access:read-only
    # Skip pod-related checks if deployment is scaled to 0
    IF    not ${SKIP_POD_CHECKS}
        # First get raw logs
        ${deployment_logs}=    RW.CLI.Run Cli
        ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} logs deployment/${DEPLOYMENT_NAME} --context ${CONTEXT} -n ${NAMESPACE} --tail=${LOG_LINES} --since=${LOG_AGE}
        ...    env=${env}
        ...    secret_file__kubeconfig=${kubeconfig}
        ...    show_in_rwl_cheatsheet=true
        ...    render_in_commandlist=true
        
        IF    ${deployment_logs.returncode} != 0
            RW.Core.Add Issue
            ...    severity=3
            ...    expected=Deployment logs should be accessible for `${DEPLOYMENT_NAME}` in namespace `${NAMESPACE}`
            ...    actual=Failed to fetch deployment logs for `${DEPLOYMENT_NAME}` in namespace `${NAMESPACE}`
            ...    title=Unable to Fetch Logs for Deployment `${DEPLOYMENT_NAME}`
            ...    reproduce_hint=${deployment_logs.cmd}
            ...    details=Log collection failed with exit code ${deployment_logs.returncode}:\n\nSTDOUT:\n${deployment_logs.stdout}\n\nSTDERR:\n${deployment_logs.stderr}
            ...    next_steps=Verify kubeconfig is valid and accessible\nCheck if context '${CONTEXT}' exists and is reachable\nVerify namespace '${NAMESPACE}' exists\nConfirm deployment '${DEPLOYMENT_NAME}' exists in the namespace\nCheck if pods are running and accessible
        ELSE
            # Filter logs to remove repetitive health check messages and focus on meaningful content
            ${filtered_logs}=    RW.CLI.Run Cli
            ...    cmd=echo "${deployment_logs.stdout}" | grep -v -E "(Checking.*Health|Health.*Check|healthcheck|/health|GET /|POST /health|probe|liveness|readiness)" | grep -E "(error|ERROR|warn|WARN|exception|Exception|fail|FAIL|fatal|FATAL|panic|stack|trace|timeout|connection.*refused|unable.*connect|authentication.*failed|denied|forbidden|unauthorized|500|502|503|504)" | tail -50 || echo "No significant errors or warnings found in recent logs"
            ...    env=${env}
            ...    include_in_history=false
            
            # Also get a sample of non-health-check logs for context
            ${context_logs}=    RW.CLI.Run Cli
            ...    cmd=echo "${deployment_logs.stdout}" | grep -v -E "(Checking.*Health|Health.*Check|healthcheck|/health|GET /|POST /health|probe|liveness|readiness)" | head -20 | tail -10
            ...    env=${env}
            ...    include_in_history=false
            
            ${history}=    RW.CLI.Pop Shell History
            
            # Determine if logs are mostly health checks
            ${total_lines}=    RW.CLI.Run Cli
            ...    cmd=echo "${deployment_logs.stdout}" | wc -l
            ...    env=${env}
            ...    include_in_history=false
            
            ${health_check_lines}=    RW.CLI.Run Cli
            ...    cmd=echo "${deployment_logs.stdout}" | grep -E "(Checking.*Health|Health.*Check|healthcheck|/health)" | wc -l
            ...    env=${env}
            ...    include_in_history=false
            
            # Handle empty output from wc -l by providing default values
            ${total_lines_clean}=    Set Variable If    "${total_lines.stdout.strip()}" == ""    0    ${total_lines.stdout.strip()}
            ${health_check_lines_clean}=    Set Variable If    "${health_check_lines.stdout.strip()}" == ""    0    ${health_check_lines.stdout.strip()}
            
            ${total_count}=    Convert To Integer    ${total_lines_clean}
            ${health_count}=    Convert To Integer    ${health_check_lines_clean}
            
            # Create consolidated logs report
            IF    ${health_count} > ${total_count} * 0.8
                ${log_content}=    Set Variable If    "${context_logs.stdout.strip()}" != ""    **🔍 Filtered Error/Warning Logs:**\n${filtered_logs.stdout}\n\n**📝 Sample Application Logs (Non-Health Check):**\n${context_logs.stdout}    **🔍 Filtered Error/Warning Logs:**\n${filtered_logs.stdout}
                RW.Core.Add Pre To Report    **📋 Log Analysis for Deployment `${DEPLOYMENT_NAME}`** (Last ${LOG_LINES} lines, ${LOG_AGE} age)\n**Total Log Lines:** ${total_count} | **Health Check Lines:** ${health_count}\n**ℹ️ Logs are mostly health check messages (${health_count}/${total_count} lines)**\n\n${log_content}\n\n**Commands Used:** ${history}
            ELSE
                RW.Core.Add Pre To Report    **📋 Log Analysis for Deployment `${DEPLOYMENT_NAME}`** (Last ${LOG_LINES} lines, ${LOG_AGE} age)\n**Total Log Lines:** ${total_count} | **Health Check Lines:** ${health_count}\n\n**📝 Recent Application Logs:**\n${deployment_logs.stdout}\n\n**Commands Used:** ${history}
            END
        END
    END



Check Liveness Probe Configuration for Deployment `${DEPLOYMENT_NAME}`
    [Documentation]    Validates if a Liveness probe has possible misconfigurations
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
    ...    access:read-only
    # Skip pod-related checks if deployment is scaled to 0
    IF    not ${SKIP_POD_CHECKS}
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
            ...    expected=Liveness probe validation should complete for deployment `${DEPLOYMENT_NAME}` in namespace `${NAMESPACE}`
            ...    actual=Failed to validate liveness probe for deployment `${DEPLOYMENT_NAME}` in namespace `${NAMESPACE}`
            ...    title=Unable to Validate Liveness Probe for Deployment `${DEPLOYMENT_NAME}`
            ...    reproduce_hint=${liveness_probe_health.cmd}
            ...    details=Validation script failed with exit code ${liveness_probe_health.returncode}:\n\nSTDOUT:\n${liveness_probe_health.stdout}\n\nSTDERR:\n${liveness_probe_health.stderr}
            ...    next_steps=Verify kubeconfig is valid and accessible\nCheck if context '${CONTEXT}' exists and is reachable\nVerify namespace '${NAMESPACE}' exists\nConfirm deployment '${DEPLOYMENT_NAME}' exists in the namespace\nCheck cluster connectivity and authentication
            ${history}=    RW.CLI.Pop Shell History
            RW.Core.Add Pre To Report    **Liveness Probe Validation Failed for Deployment `${DEPLOYMENT_NAME}`**\n\nFailed to validate liveness probe:\n\n${liveness_probe_health.stderr}\n\n**Commands Used:** ${liveness_probe_health.cmd}
        ELSE
            ${recommendations}=    RW.CLI.Run Cli
            ...    cmd=awk '/Recommended Next Steps:/ {flag=1; next} flag' "liveness_probe_output"
            ...    env=${env}
            ...    include_in_history=false
            ${rec_length}=    Get Length    ${recommendations.stdout}
            IF    ${rec_length} > 0
                RW.Core.Add Issue
                ...    severity=2
                ...    expected=Liveness probes should be configured and functional for deployment `${DEPLOYMENT_NAME}` in namespace `${NAMESPACE}`
                ...    actual=Issues found with liveness probe configuration for deployment `${DEPLOYMENT_NAME}` in namespace `${NAMESPACE}`
                ...    title=Configuration Issues with Deployment `${DEPLOYMENT_NAME}` in namespace `${NAMESPACE}`
                ...    reproduce_hint=View Commands Used in Report Output
                ...    details=Liveness Probe Configuration Issues with Deployment ${DEPLOYMENT_NAME}\n${liveness_probe_health.stdout}
                ...    next_steps=${recommendations.stdout}
            END
            ${history}=    RW.CLI.Pop Shell History
            RW.Core.Add Pre To Report    **Liveness Probe Testing Results for Deployment `${DEPLOYMENT_NAME}`**\n\n${liveness_probe_health.stdout}\n\n**Commands Used:** ${liveness_probe_health.cmd}
        END
    END

Check Readiness Probe Configuration for Deployment `${DEPLOYMENT_NAME}` in Namespace `${NAMESPACE}`
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
    ...    access:read-only
    # Skip pod-related checks if deployment is scaled to 0
    IF    not ${SKIP_POD_CHECKS}
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
            ...    expected=Readiness probe validation should complete for deployment `${DEPLOYMENT_NAME}` in namespace `${NAMESPACE}`
            ...    actual=Failed to validate readiness probe for deployment `${DEPLOYMENT_NAME}` in namespace `${NAMESPACE}`
            ...    title=Unable to Validate Readiness Probe for Deployment `${DEPLOYMENT_NAME}`
            ...    reproduce_hint=${readiness_probe_health.cmd}
            ...    details=Validation script failed with exit code ${readiness_probe_health.returncode}:\n\nSTDOUT:\n${readiness_probe_health.stdout}\n\nSTDERR:\n${readiness_probe_health.stderr}
            ...    next_steps=Verify kubeconfig is valid and accessible\nCheck if context '${CONTEXT}' exists and is reachable\nVerify namespace '${NAMESPACE}' exists\nConfirm deployment '${DEPLOYMENT_NAME}' exists in the namespace\nCheck cluster connectivity and authentication
            ${history}=    RW.CLI.Pop Shell History
            RW.Core.Add Pre To Report    **Readiness Probe Validation Failed for Deployment `${DEPLOYMENT_NAME}`**\n\nFailed to validate readiness probe:\n\n${readiness_probe_health.stderr}\n\n**Commands Used:** ${readiness_probe_health.cmd}
        ELSE
            ${recommendations}=    RW.CLI.Run Cli
            ...    cmd=awk '/Recommended Next Steps:/ {flag=1; next} flag' "readiness_probe_output"
            ...    env=${env}
            ...    include_in_history=false
            ${rec_length}=    Get Length    ${recommendations.stdout}
            IF    ${rec_length} > 0
                RW.Core.Add Issue
                ...    severity=2
                ...    expected=Readiness probes should be configured and functional for deployment `${DEPLOYMENT_NAME}` in namespace `${NAMESPACE}`
                ...    actual=Issues found with readiness probe configuration for deployment `${DEPLOYMENT_NAME}` in namespace `${NAMESPACE}`
                ...    title=Configuration Issues with Deployment `${DEPLOYMENT_NAME}` in namespace `${NAMESPACE}`
                ...    reproduce_hint=View Commands Used in Report Output
                ...    details=Readiness Probe Issues with Deployment ${DEPLOYMENT_NAME}\n${readiness_probe_health.stdout}
                ...    next_steps=${recommendations.stdout}
            END
            ${history}=    RW.CLI.Pop Shell History
            RW.Core.Add Pre To Report    **Readiness Probe Validation Results for Deployment `${DEPLOYMENT_NAME}`**\n\n${readiness_probe_health.stdout}\n\n**Commands Used:** ${readiness_probe_health.cmd}
        END
    END

Inspect Deployment Warning Events for `${DEPLOYMENT_NAME}` in Namespace `${NAMESPACE}`
    [Documentation]    Fetches warning events related to the deployment workload in the namespace and triages any issues found in the events.
    [Tags]    access:read-only  events    workloads    errors    warnings    get    deployment    ${DEPLOYMENT_NAME}
    # Use EVENT_AGE from SLI configuration to align with SLI frequency (10m + buffer = 15m)
    ${events}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get events --context ${CONTEXT} -n ${NAMESPACE} -o json | jq '(now - (60*15)) as $time_limit | [ .items[] | select(.type == "Warning" and (.involvedObject.kind == "Deployment" or .involvedObject.kind == "Pod" or .involvedObject.kind == "ReplicaSet") and (.involvedObject.name | tostring | contains("${DEPLOYMENT_NAME}")) and (.lastTimestamp // empty | if . then fromdateiso8601 else 0 end) >= $time_limit) | {kind: .involvedObject.kind, name: .involvedObject.name, reason: .reason, message: .message, firstTimestamp: .firstTimestamp, lastTimestamp: .lastTimestamp, count: .count} ] | group_by([.kind, .name]) | map(if length > 0 then {kind: .[0].kind, name: .[0].name, total_count: (map(.count // 1) | add), reasons: (map(.reason) | unique), messages: (map(.message) | unique), firstTimestamp: (map(.firstTimestamp // empty | if . then fromdateiso8601 else 0 end) | sort | .[0] | if . > 0 then todateiso8601 else null end), lastTimestamp: (map(.lastTimestamp // empty | if . then fromdateiso8601 else 0 end) | sort | reverse | .[0] | if . > 0 then todateiso8601 else null end)} else empty end) | map(. + {summary: "\(.kind) \(.name): \(.total_count) events (\(.reasons | join(", ")))"}) | {events_summary: map(.summary), total_objects: length, events: .}'
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    show_in_rwl_cheatsheet=true
    ...    render_in_commandlist=true
    
    # Check for command failure and create generic issue if needed
    IF    ${events.returncode} != 0
        RW.Core.Add Issue
        ...    severity=2
        ...    expected=Deployment warning events should be retrievable for `${DEPLOYMENT_NAME}` in namespace `${NAMESPACE}`
        ...    actual=Failed to retrieve deployment warning events for `${DEPLOYMENT_NAME}` in namespace `${NAMESPACE}`
        ...    title=Unable to Fetch Warning Events for Deployment `${DEPLOYMENT_NAME}`
        ...    reproduce_hint=${events.cmd}
        ...    details=Command failed with exit code ${events.returncode}:\n\nSTDOUT:\n${events.stdout}\n\nSTDERR:\n${events.stderr}
        ...    next_steps=Verify kubeconfig is valid and accessible\nCheck if context '${CONTEXT}' exists and is reachable\nVerify namespace '${NAMESPACE}' exists\nConfirm deployment '${DEPLOYMENT_NAME}' exists in the namespace\nCheck cluster connectivity and authentication
        ${history}=    RW.CLI.Pop Shell History
        RW.Core.Add Pre To Report    **Event Retrieval Failed for Deployment `${DEPLOYMENT_NAME}`**\n\nFailed to retrieve events:\n\n${events.stderr}\n\n**Commands Used:** ${history}
    ELSE
        # Collect ALL events (Normal + Warning) for last 15 minutes (aligned with SLI frequency + buffer) including Deployment, ReplicaSet, and Pod levels
        ${all_events}=    RW.CLI.Run Cli
        ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get events --context ${CONTEXT} -n ${NAMESPACE} -o json | jq --argjson minutes 15 '(now - ($minutes * 60)) as $time_limit | [.items[] | select((.involvedObject.kind == "Deployment" or .involvedObject.kind == "Pod" or .involvedObject.kind == "ReplicaSet") and (.involvedObject.name | tostring | contains("${DEPLOYMENT_NAME}")) and (.lastTimestamp // empty | if . then fromdateiso8601 else now end) >= $time_limit)] | sort_by(.lastTimestamp // .firstTimestamp) | {total_events: length, normal_events: (map(select(.type == "Normal")) | length), warning_events: (map(select(.type == "Warning")) | length), deployment_events: (map(select(.involvedObject.kind == "Deployment")) | length), replicaset_events: (map(select(.involvedObject.kind == "ReplicaSet")) | length), pod_events: (map(select(.involvedObject.kind == "Pod")) | length), events_by_type: (group_by(.type) | map({type: .[0].type, count: length, reasons: (map(.reason) | group_by(.) | map({reason: .[0], count: length}))})), chronological_events: (map({timestamp: (.lastTimestamp // .firstTimestamp), type: .type, kind: .involvedObject.kind, name: .involvedObject.name, reason: .reason, message: .message}) | sort_by(.timestamp)), recent_warnings: (map(select(.type == "Warning")) | map({timestamp: (.lastTimestamp // .firstTimestamp), kind: .involvedObject.kind, name: .involvedObject.name, reason: .reason, message: .message}) | sort_by(.timestamp) | reverse | .[0:10])}'
        ...    env=${env}
        ...    secret_file__kubeconfig=${kubeconfig}
        ...    include_in_history=false
        
        TRY
            ${event_data}=    Evaluate    json.loads(r'''${all_events.stdout}''') if r'''${all_events.stdout}'''.strip() else {}    json
            ${warning_count}=    Evaluate    $event_data.get('warning_events', 0)
            ${total_count}=    Evaluate    $event_data.get('total_events', 0)
            
            # Build comprehensive event report
            RW.Core.Add Pre To Report    **📊 Complete Event Summary for Deployment `${DEPLOYMENT_NAME}` (Last 15 Minutes)**\n**Total Events:** ${total_count} (${event_data.get('normal_events', 0)} Normal, ${event_data.get('warning_events', 0)} Warning)\n**Event Distribution:** ${event_data.get('deployment_events', 0)} Deployment, ${event_data.get('replicaset_events', 0)} ReplicaSet, ${event_data.get('pod_events', 0)} Pod
            
            IF    ${warning_count} > 0
                ${event_object_data}=    Evaluate    json.loads(r'''${events.stdout}''') if r'''${events.stdout}'''.strip() else {}    json
                ${object_list}=    Evaluate    $event_object_data.get('events', [])
                
                # Check if deployment is currently scaled to 0 to filter stale events
                ${deployment_scaled_down}=    Set Variable    ${SKIP_POD_CHECKS}
                
                # Get current pod list to filter out events for non-existent pods
                # First get the deployment's actual label selector instead of assuming app=${DEPLOYMENT_NAME}
                ${deployment_selector}=    RW.CLI.Run Cli
                ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get deployment ${DEPLOYMENT_NAME} --context ${CONTEXT} -n ${NAMESPACE} -o json | jq -r '.spec.selector.matchLabels | to_entries | map("\(.key)=\(.value)") | join(",")'
                ...    env=${env}
                ...    secret_file__kubeconfig=${kubeconfig}
                ...    include_in_history=false
                
                ${current_pods}=    RW.CLI.Run Cli
                ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get pods --context ${CONTEXT} -n ${NAMESPACE} -l ${deployment_selector.stdout} -o json | jq -r '.items[].metadata.name'
                ...    env=${env}
                ...    secret_file__kubeconfig=${kubeconfig}
                ...    include_in_history=false
                
                ${existing_pod_names}=    Create List
                IF    ${deployment_selector.returncode} == 0 and '''${deployment_selector.stdout}''' != '' and ${current_pods.returncode} == 0 and '''${current_pods.stdout}''' != ''
                    @{pod_lines}=    Split String    ${current_pods.stdout}    \n
                    FOR    ${pod_name}    IN    @{pod_lines}
                        ${trimmed_pod}=    Strip String    ${pod_name}
                        IF    '''${trimmed_pod}''' != ''
                            Append To List    ${existing_pod_names}    ${trimmed_pod}
                        END
                    END
                ELSE
                    Log    Warning: Could not retrieve deployment selector or current pods, skipping pod existence filtering
                END
                
                # Get current deployment health status for context
                ${deployment_health}=    RW.CLI.Run Cli
                ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get deployment/${DEPLOYMENT_NAME} --context ${CONTEXT} -n ${NAMESPACE} -o json | jq '{name: .metadata.name, desired_replicas: .spec.replicas, ready_replicas: (.status.readyReplicas // 0), available_replicas: (.status.availableReplicas // 0), unavailable_replicas: (.status.unavailableReplicas // 0), conditions: [.status.conditions[]? | select(.type == "Available" or .type == "Progressing") | {type: .type, status: .status, reason: .reason, message: .message}]}'
                ...    env=${env}
                ...    secret_file__kubeconfig=${kubeconfig}
                ...    include_in_history=false
                
                ${health_context}=    Set Variable    **Current Deployment Status:** Unable to retrieve
                IF    ${deployment_health.returncode} == 0 and '''${deployment_health.stdout}''' != ''
                    TRY
                        ${health_data}=    Evaluate    json.loads(r'''${deployment_health.stdout}''') if r'''${deployment_health.stdout}'''.strip() else {}    json
                        ${desired}=    Evaluate    $health_data.get('desired_replicas', 0)
                        ${ready}=    Evaluate    $health_data.get('ready_replicas', 0)
                        ${available}=    Evaluate    $health_data.get('available_replicas', 0)
                        ${unavailable}=    Evaluate    $health_data.get('unavailable_replicas', 0)
                        ${conditions}=    Evaluate    $health_data.get('conditions', [])
                        
                        ${health_context}=    Set Variable    **Current Deployment Status:** ${ready}/${desired} ready replicas, ${available} available, ${unavailable} unavailable
                        
                        # Add condition details if available
                        FOR    ${condition}    IN    @{conditions}
                            ${cond_type}=    Evaluate    $condition.get('type', 'Unknown')
                            ${cond_status}=    Evaluate    $condition.get('status', 'Unknown')
                            ${cond_reason}=    Evaluate    $condition.get('reason', '')
                            ${health_context}=    Catenate    ${health_context}    \n**${cond_type}:** ${cond_status} (${cond_reason})
                        END
                    EXCEPT
                        Log    Warning: Failed to parse deployment health status
                    END
                END
                
                # Create consolidated issues for warnings found
                ${object_list_length}=    Get Length    ${object_list}
                IF    ${object_list_length} > 0
                    # Consolidate issues by collecting unique issue types and their details
                    ${consolidated_issues}=    Create Dictionary
                    ${total_affected_objects}=    Set Variable    ${0}
                    
                    FOR    ${item}    IN    @{object_list}
                        ${total_affected_objects}=    Evaluate    ${total_affected_objects} + 1
                        ${message_string}=    Catenate    SEPARATOR=;    @{item["messages"]}
                        ${messages}=    RW.K8sHelper.Sanitize Messages    ${message_string}
                        
                        # Skip stale pod events if deployment is scaled down or pod no longer exists
                        ${skip_stale_event}=    Set Variable    ${False}
                        
                        # Check if this is a pod event for a non-existent pod
                        IF    '${item["kind"]}' == 'Pod'
                            ${pod_name}=    Set Variable    ${item["name"]}
                            ${pod_exists}=    Evaluate    "${pod_name}" in $existing_pod_names
                            IF    not ${pod_exists}
                                ${skip_stale_event}=    Set Variable    ${True}
                                Log    Skipping event for non-existent pod: ${pod_name}
                            END
                        END
                        
                        # Also skip stale events if deployment is scaled down
                        IF    not ${skip_stale_event} and ${deployment_scaled_down} and '${item["kind"]}' == 'Pod'
                            # Find scale-down timestamp from chronological events
                            ${scale_events}=    Evaluate    [event for event in $event_data.get('chronological_events', []) if 'ScalingReplicaSet' in event.get('reason', '') and 'Scaled down' in event.get('message', '')]
                            ${scale_events_length}=    Get Length    ${scale_events}
                            IF    ${scale_events_length} > 0
                                ${latest_scale_event}=    Evaluate    $scale_events[-1]
                                ${scale_down_timestamp}=    Evaluate    $latest_scale_event.get('timestamp', '')
                                ${event_timestamp}=    Set Variable    ${item.get("lastTimestamp", "")}
                                
                                # Check if this event is from before scale-down
                                IF    "${event_timestamp}" < "${scale_down_timestamp}"
                                    ${skip_stale_event}=    Set Variable    ${True}
                                    Log    Skipping stale pod event from before scale-down: ${item["kind"]}/${item["name"]} at ${event_timestamp} (scale-down at ${scale_down_timestamp})
                                END
                            END
                        END
                        
                        IF    not ${skip_stale_event}
                            ${issues}=    RW.CLI.Run Bash File
                            ...    bash_file=workload_issues.sh
                            ...    cmd_override=./workload_issues.sh "${messages}" "Deployment" "${DEPLOYMENT_NAME}"
                            ...    env=${env}
                            ...    include_in_history=False
                            
                            TRY
                                ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''') if r'''${issues.stdout}'''.strip() else []    json
                                FOR    ${issue}    IN    @{issue_list}
                                    ${issue_key}=    Set Variable    ${issue["title"]}
                                    
                                    # Consolidate issues by title
                                    IF    "${issue_key}" in $consolidated_issues
                                        ${existing_issue}=    Evaluate    $consolidated_issues["${issue_key}"]
                                        ${updated_count}=    Evaluate    $existing_issue.get('count', 1) + 1
                                        ${updated_objects}=    Catenate    ${existing_issue.get('affected_objects', '')}    ${item["kind"]}/${item["name"]},${SPACE}
                                        # Merge reasons from multiple items
                                        ${existing_reasons}=    Evaluate    set($existing_issue.get('consolidated_reasons', []))
                                        ${new_reasons}=    Evaluate    $existing_reasons.union(set($item.get('reasons', [])))
                                        # Preserve event details for each resource
                                        ${existing_events}=    Evaluate    $existing_issue.get('event_details', [])
                                        ${new_event}=    Evaluate    {'resource': "${item["kind"]}/${item["name"]}", 'reasons': $item.get('reasons', []), 'messages': $item.get('messages', []), 'count': $item.get('total_count', 1)}
                                        ${updated_events}=    Evaluate    $existing_events + [$new_event]
                                        ${updated_issue}=    Evaluate    {**$existing_issue, 'count': ${updated_count}, 'affected_objects': "${updated_objects}", 'consolidated_reasons': list($new_reasons), 'event_details': $updated_events}
                                        ${updated_dict}=    Evaluate    {**$consolidated_issues, "${issue_key}": $updated_issue}
                                        Set Test Variable    ${consolidated_issues}    ${updated_dict}
                                    ELSE
                                        ${new_event}=    Evaluate    {'resource': "${item["kind"]}/${item["name"]}", 'reasons': $item.get('reasons', []), 'messages': $item.get('messages', []), 'count': $item.get('total_count', 1)}
                                        ${new_issue}=    Evaluate    {**$issue, 'count': 1, 'affected_objects': "${item["kind"]}/${item["name"]}, ", 'consolidated_reasons': $item.get('reasons', []), 'event_details': [$new_event]}
                                        ${updated_dict}=    Evaluate    {**$consolidated_issues, "${issue_key}": $new_issue}
                                        Set Test Variable    ${consolidated_issues}    ${updated_dict}
                                    END
                                END
                            EXCEPT
                                Log    Warning: Failed to parse workload issues for ${item["kind"]} ${item["name"]}
                            END
                        END
                    END
                    
                    # Create consolidated issues
                    ${issue_keys}=    Evaluate    list($consolidated_issues.keys())
                    FOR    ${issue_key}    IN    @{issue_keys}
                        ${issue}=    Evaluate    $consolidated_issues["${issue_key}"]
                        ${count}=    Evaluate    $issue.get('count', 1)
                        ${affected_objects}=    Evaluate    $issue.get('affected_objects', '').rstrip(', ')
                        
                        # For consolidated issues, create appropriate title based on deployment context
                        ${base_title}=    Set Variable    ${issue["title"]}
                        ${consolidated_reasons}=    Evaluate    $issue.get('consolidated_reasons', [])
                        ${reasons_count}=    Get Length    ${consolidated_reasons}
                        
                        # Always focus on the deployment since pod issues are usually deployment config problems
                        IF    ${reasons_count} > 0 and ${reasons_count} <= 3
                            ${reasons_str}=    Evaluate    ', '.join($consolidated_reasons)
                            ${enhanced_title}=    Set Variable    ${base_title} in Deployment `${DEPLOYMENT_NAME}` (${reasons_str})
                        ELSE
                            ${enhanced_title}=    Set Variable    ${base_title} in Deployment `${DEPLOYMENT_NAME}`
                        END
                        
                        # Update details to show pod count rather than individual pod names for clarity
                        IF    ${count} > 1
                            # Count pods vs other resource types
                            ${pod_count}=    Evaluate    len([obj for obj in "${affected_objects}".split(", ") if obj.strip().startswith("Pod/")])
                            ${other_count}=    Evaluate    ${count} - ${pod_count}
                            
                            IF    ${pod_count} > 0 and ${other_count} == 0
                                ${details_prefix}=    Set Variable    **Issue affects ${pod_count} pods in Deployment `${DEPLOYMENT_NAME}`**\n\n
                            ELSE IF    ${pod_count} > 0 and ${other_count} > 0
                                ${details_prefix}=    Set Variable    **Issue affects ${pod_count} pods and ${other_count} other resources in Deployment `${DEPLOYMENT_NAME}`**\n\n
                            ELSE
                                ${details_prefix}=    Set Variable    **Affected Resources:** ${affected_objects}\n\n
                            END
                        ELSE
                            ${details_prefix}=    Set Variable    **Affected Resource:** ${affected_objects}\n\n
                        END
                        
                        # Add event details section
                        ${event_details_list}=    Evaluate    $issue.get('event_details', [])
                        ${event_details_str}=    Set Variable    **Warning Events:**\n
                        FOR    ${event_detail}    IN    @{event_details_list}
                            ${resource}=    Evaluate    $event_detail.get('resource', 'Unknown')
                            ${event_count}=    Evaluate    $event_detail.get('count', 1)
                            ${event_messages}=    Evaluate    $event_detail.get('messages', [])
                            ${event_reasons}=    Evaluate    $event_detail.get('reasons', [])
                            
                            ${event_details_str}=    Catenate    ${event_details_str}    • **${resource}** (${event_count} events)\n
                            ${reasons_str}=    Evaluate    ', '.join($event_reasons)
                            IF    "${reasons_str}" != ""
                                ${event_details_str}=    Catenate    ${event_details_str}      **Reasons:** ${reasons_str}\n
                            END
                            
                            # Show up to 3 unique messages per resource
                            ${unique_messages}=    Evaluate    list(dict.fromkeys($event_messages))[:3]
                            FOR    ${message}    IN    @{unique_messages}
                                ${event_details_str}=    Catenate    ${event_details_str}      **Message:** ${message}\n
                            END
                            ${event_details_str}=    Catenate    ${event_details_str}    \n
                        END
                        
                        # Determine if this is a deployment-level issue or pod-level issue
                        ${is_deployment_issue}=    Evaluate    any(event.get('resource', '').startswith('Deployment/') for event in $issue.get('event_details', []))
                        ${pod_count}=    Evaluate    len([event for event in $issue.get('event_details', []) if event.get('resource', '').startswith('Pod/')])
                        
                        # Create more accurate issue descriptions
                        IF    ${is_deployment_issue}
                            ${actual_description}=    Set Variable    Deployment-level issues detected for `${DEPLOYMENT_NAME}` in namespace `${NAMESPACE}`
                        ELSE IF    ${pod_count} > 0
                            ${actual_description}=    Set Variable    Pod-level issues detected in ${pod_count} pod(s) of deployment `${DEPLOYMENT_NAME}` - deployment may still be functional
                        ELSE
                            ${actual_description}=    Set Variable    ${enhanced_title} detected for deployment `${DEPLOYMENT_NAME}` in namespace `${NAMESPACE}`
                        END
                        
                        # Adjust severity based on current deployment health
                        ${adjusted_severity}=    Set Variable    ${issue["severity"]}
                        IF    '''${health_context}''' != '''**Current Deployment Status:** Unable to retrieve'''
                            # Check if deployment is healthy (has ready replicas and is available)
                            ${has_zero_ready}=    Evaluate    __import__('re').search(r'\b0/\d+\s+ready replicas', '''${health_context}''') is not None    modules=re
                            ${is_healthy}=    Evaluate    "ready replicas" in '''${health_context}''' and "True" in '''${health_context}''' and not ${has_zero_ready}
                            
                            # Lower severity for probe failures when deployment is healthy
                            ${is_probe_issue}=    Evaluate    "probe failures" in '''${enhanced_title}'''.lower()
                            IF    ${is_healthy} and ${is_probe_issue}
                                ${adjusted_severity}=    Set Variable    4
                                Log    Lowering severity to 4 for probe failures in healthy deployment ${DEPLOYMENT_NAME}
                            END
                        END
                        
                        RW.Core.Add Issue
                        ...    severity=${adjusted_severity}
                        ...    expected=No warning events should be present for deployment `${DEPLOYMENT_NAME}` in namespace `${NAMESPACE}`
                        ...    actual=${actual_description}
                        ...    title=${enhanced_title}
                        ...    reproduce_hint=${events.cmd}
                        ...    details=${health_context}\n\n${details_prefix}${event_details_str}${issue["details"]}
                        ...    next_steps=${issue["next_steps"]}
                    END
                    
                    # Add note about filtered stale events if applicable
                    IF    ${deployment_scaled_down}
                        ${issue_keys_length}=    Get Length    ${issue_keys}
                        ${filtered_count}=    Evaluate    ${total_affected_objects} - ${issue_keys_length}
                        # Note: Filtered events count is now included in the consolidated event report below
                    END
                END
                
                # Build warning categories list
                ${warning_categories}=    Set Variable    ${EMPTY}
                FOR    ${event_type}    IN    @{event_data.get('events_by_type', [])}
                    IF    '${event_type["type"]}' == 'Warning'
                        FOR    ${reason_info}    IN    @{event_type.get('reasons', [])}
                            ${warning_categories}=    Catenate    ${warning_categories}    - **${reason_info["reason"]}**: ${reason_info["count"]} events\n
                        END
                    END
                END
                
                # Build event timeline
                ${recent_events}=    Evaluate    $event_data.get('chronological_events', [])[-10:]
                ${timeline_content}=    Set Variable    ${EMPTY}
                FOR    ${event}    IN    @{recent_events}
                    ${event_emoji}=    Set Variable If    '${event["type"]}' == 'Warning'    ⚠️    ℹ️
                    ${timeline_content}=    Catenate    ${timeline_content}    ${event_emoji} **${event["timestamp"]}** [${event["kind"]}/${event["name"]}] ${event["reason"]}: ${event["message"]}\n
                END
                
                # Build filtered events note if applicable
                ${filtered_note}=    Set Variable    ${EMPTY}
                IF    ${deployment_scaled_down}
                    ${issue_keys_length}=    Get Length    ${issue_keys}
                    ${filtered_count}=    Evaluate    ${total_affected_objects} - ${issue_keys_length}
                    IF    ${filtered_count} > 0
                        ${filtered_note}=    Set Variable    \n\n**ℹ️ Note:** Filtered ${filtered_count} stale pod events from before scale-down
                    END
                END
                
                RW.Core.Add Pre To Report    **⚠️ Recent Warning Events:** ${warning_count} warnings detected\n\n**Warning Event Categories:**\n${warning_categories}\n**🕒 Recent Event Timeline (Last 10 Events):**\n${timeline_content}${filtered_note}
            ELSE
                # Build event timeline for clean events
                ${recent_events}=    Evaluate    $event_data.get('chronological_events', [])[-10:]
                ${timeline_content}=    Set Variable    ${EMPTY}
                FOR    ${event}    IN    @{recent_events}
                    ${event_emoji}=    Set Variable If    '${event["type"]}' == 'Warning'    ⚠️    ℹ️
                    ${timeline_content}=    Catenate    ${timeline_content}    ${event_emoji} **${event["timestamp"]}** [${event["kind"]}/${event["name"]}] ${event["reason"]}: ${event["message"]}\n
                END
                
                RW.Core.Add Pre To Report    **✅ No Warning Events:** Clean event history\n\n**🕒 Recent Event Timeline (Last 10 Events):**\n${timeline_content}
            END
            
        EXCEPT
            RW.Core.Add Pre To Report    **Event Collection:** Completed but detailed parsing failed
        END
        
        ${history}=    RW.CLI.Pop Shell History
        RW.Core.Add Pre To Report    **Deployment Replica Status Commands for `${DEPLOYMENT_NAME}`**\n\n**Commands Used:** ${history}
    END

Check Deployment Replica Status for `${DEPLOYMENT_NAME}` in Namespace `${NAMESPACE}`
    [Documentation]    Inspects the deployment replica status including desired vs available replicas and identifies any scaling issues.
    [Tags]    access:read-only    deployment    replicas    scaling    status    ${DEPLOYMENT_NAME}
    ${replica_status}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get deployment/${DEPLOYMENT_NAME} --context ${CONTEXT} -n ${NAMESPACE} -o json | jq '{name: .metadata.name, namespace: .metadata.namespace, spec_replicas: .spec.replicas, status_replicas: (.status.replicas // 0), ready_replicas: (.status.readyReplicas // 0), available_replicas: (.status.availableReplicas // 0), unavailable_replicas: (.status.unavailableReplicas // 0), updated_replicas: (.status.updatedReplicas // 0), conditions: .status.conditions, strategy: .spec.strategy, debug: {spec_replicas: .spec.replicas, status_replicas: .status.replicas, ready_replicas: .status.readyReplicas, available_replicas: .status.availableReplicas}}'
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    show_in_rwl_cheatsheet=true
    ...    render_in_commandlist=true
    
    IF    ${replica_status.returncode} != 0
        RW.Core.Add Issue
        ...    severity=1
        ...    expected=Deployment replica status should be retrievable for `${DEPLOYMENT_NAME}` in namespace `${NAMESPACE}`
        ...    actual=Failed to retrieve deployment replica status for `${DEPLOYMENT_NAME}` in namespace `${NAMESPACE}`
        ...    title=Unable to Check Replica Status for Deployment `${DEPLOYMENT_NAME}`
        ...    reproduce_hint=${replica_status.cmd}
        ...    details=Command failed with exit code ${replica_status.returncode}:\n\nSTDOUT:\n${replica_status.stdout}\n\nSTDERR:\n${replica_status.stderr}
        ...    next_steps=Verify kubeconfig is valid and accessible\nCheck if context '${CONTEXT}' exists and is reachable\nVerify namespace '${NAMESPACE}' exists\nConfirm deployment '${DEPLOYMENT_NAME}' exists in the namespace
    ELSE
        TRY
            ${status_data}=    Evaluate    json.loads(r'''${replica_status.stdout}''')    json
            ${desired_replicas}=    Evaluate    $status_data.get('spec_replicas', 0)
            ${ready_replicas}=    Evaluate    $status_data.get('ready_replicas', 0)
            ${available_replicas}=    Evaluate    $status_data.get('available_replicas', 0)
            ${unavailable_replicas}=    Evaluate    $status_data.get('unavailable_replicas', 0)
            
            # Create status message based on replica health
            IF    ${desired_replicas} == 0
                ${replica_status_msg}=    Set Variable    ℹ️ Deployment is intentionally scaled to 0 replicas
            ELSE IF    ${ready_replicas} == ${desired_replicas}
                ${replica_status_msg}=    Set Variable    ✅ Replica status is healthy
            ELSE
                ${replica_status_msg}=    Set Variable    ⚠️ Replica issues detected
            END
            
            RW.Core.Add Pre To Report    **Deployment Replica Status for `${DEPLOYMENT_NAME}`**\n**Desired:** ${desired_replicas} | **Ready:** ${ready_replicas} | **Available:** ${available_replicas} | **Unavailable:** ${unavailable_replicas}\n**Debug Info:** ${status_data.get('debug', {})}\n\n${replica_status_msg}
            
            # Check for scaling issues (corrected logic for scale-to-zero)
            IF    ${ready_replicas} == 0 and ${desired_replicas} > 0
                RW.Core.Add Issue
                ...    severity=1
                ...    expected=${desired_replicas} ready replicas for deployment `${DEPLOYMENT_NAME}` in namespace `${NAMESPACE}`
                ...    actual=${ready_replicas} ready replicas for deployment `${DEPLOYMENT_NAME}` in namespace `${NAMESPACE}`
                ...    title=Deployment `${DEPLOYMENT_NAME}` Has No Ready Replicas
                ...    reproduce_hint=${replica_status.cmd}
                ...    details=Deployment is configured to run ${desired_replicas} replicas but has ${ready_replicas} ready replicas.\n\nStatus: Ready=${ready_replicas}, Available=${available_replicas}, Unavailable=${unavailable_replicas}
                ...    next_steps=Check pod status and events for deployment issues\nInvestigate resource constraints or scheduling problems\nReview deployment configuration and health checks
            ELSE IF    ${ready_replicas} < ${desired_replicas} and ${desired_replicas} > 0
                ${missing_replicas}=    Evaluate    ${desired_replicas} - ${ready_replicas}
                RW.Core.Add Issue
                ...    severity=2
                ...    expected=${desired_replicas} ready replicas for deployment `${DEPLOYMENT_NAME}` in namespace `${NAMESPACE}`
                ...    actual=${ready_replicas} ready replicas for deployment `${DEPLOYMENT_NAME}` in namespace `${NAMESPACE}`
                ...    title=Deployment `${DEPLOYMENT_NAME}` is Missing Ready Replicas
                ...    reproduce_hint=${replica_status.cmd}
                ...    details=Deployment needs ${missing_replicas} more ready replicas to meet desired state of ${desired_replicas}.\n\nStatus: Ready=${ready_replicas}, Available=${available_replicas}, Unavailable=${unavailable_replicas}
                ...    next_steps=Check pod status and events for scaling issues\nInvestigate resource constraints or scheduling problems\nReview deployment rollout status
            ELSE IF    ${desired_replicas} == 0
                # Status already shown in consolidated report
                Log    Deployment is scaled to 0 replicas
            ELSE
                # Status already shown in consolidated report  
                Log    Replica status is healthy
            END
            
        EXCEPT
            Log    Warning: Failed to parse replica status JSON
            RW.Core.Add Issue
            ...    severity=3
            ...    expected=Replica status should be parseable for deployment `${DEPLOYMENT_NAME}` in namespace `${NAMESPACE}`
            ...    actual=Failed to parse replica status for deployment `${DEPLOYMENT_NAME}` in namespace `${NAMESPACE}`
            ...    title=Replica Status Parsing Failed for Deployment `${DEPLOYMENT_NAME}`
            ...    reproduce_hint=${replica_status.cmd}
            ...    details=Command succeeded but JSON parsing failed. Raw output:\n${replica_status.stdout}
            ...    next_steps=Review deployment status output manually\nCheck for formatting issues in kubectl output
        END
        
        ${history}=    RW.CLI.Pop Shell History
        RW.Core.Add Pre To Report    **Deployment Replica Status Commands for `${DEPLOYMENT_NAME}`**\n\n**Commands Used:** ${history}
    END

Inspect Container Restarts for Deployment `${DEPLOYMENT_NAME}` in Namespace `${NAMESPACE}`
    [Documentation]    Checks for container restarts and provides details on restart patterns that might indicate application issues.
    [Tags]    access:read-only    containers    restarts    pods    deployment    ${DEPLOYMENT_NAME}
    # Skip pod-related checks if deployment is scaled to 0
    IF    not ${SKIP_POD_CHECKS}
        ${container_restarts}=    RW.CLI.Run Bash File
        ...    bash_file=container_restarts.sh
        ...    env=${env}
        ...    secret_file__kubeconfig=${kubeconfig}
        ...    include_in_history=false
        
        IF    ${container_restarts.returncode} != 0
            RW.Core.Add Issue
            ...    severity=3
            ...    expected=Container restart analysis should complete successfully for deployment `${DEPLOYMENT_NAME}` in namespace `${NAMESPACE}`
            ...    actual=Failed to analyze container restarts for deployment `${DEPLOYMENT_NAME}` in namespace `${NAMESPACE}`
            ...    title=Container Restart Analysis Failed for Deployment `${DEPLOYMENT_NAME}`
            ...    reproduce_hint=${container_restarts.cmd}
            ...    details=Restart analysis failed with exit code ${container_restarts.returncode}:\n\nSTDOUT:\n${container_restarts.stdout}\n\nSTDERR:\n${container_restarts.stderr}
            ...    next_steps=Verify pod access and kubectl connectivity\nCheck if deployment exists and has running pods\nReview container restart analysis script
        ELSE
            TRY
                # Try to parse as JSON first, but handle plain text responses gracefully
                ${output_text}=    Set Variable    ${container_restarts.stdout.strip()}
                
                # Look for JSON in the output (may be mixed with text)
                ${json_match}=    Evaluate    __import__('re').search(r'\\{.*\\}', r'''${output_text}''', __import__('re').DOTALL)    modules=re
                
                IF    ${json_match}
                    ${json_text}=    Evaluate    $json_match.group(0) if $json_match else '{}'
                    ${restart_data}=    Evaluate    json.loads(r'''${json_text}''')    json
                    ${restart_issues}=    Evaluate    $restart_data.get('issues', [])
                    ${restart_summary}=    Evaluate    $restart_data.get('summary', {})
                    ${is_json}=    Set Variable    ${True}
                ELSE
                    # Handle plain text response (no restarts found)
                    ${restart_data}=    Create Dictionary    issues=@{EMPTY}    summary=@{EMPTY}
                    ${restart_issues}=    Create List
                    ${restart_summary}=    Create Dictionary    total_containers=0    containers_with_restarts=0
                    ${is_json}=    Set Variable    ${False}
                END
                
                FOR    ${issue}    IN    @{restart_issues}
                    RW.Core.Add Issue
                    ...    severity=${issue.get('severity', 3)}
                    ...    expected=Containers should run without frequent restarts for deployment `${DEPLOYMENT_NAME}` in namespace `${NAMESPACE}`
                    ...    actual=${issue.get('title', 'Container restart issue detected')} in deployment `${DEPLOYMENT_NAME}` in namespace `${NAMESPACE}`
                    ...    title=${issue.get('title', 'Container Restart Issue')} in Deployment `${DEPLOYMENT_NAME}`
                    ...    reproduce_hint=Check container status and logs for deployment `${DEPLOYMENT_NAME}` in namespace `${NAMESPACE}`
                    ...    details=${issue.get('details', 'Container restart analysis detected potential issues')}
                    ...    next_steps=${issue.get('next_steps', 'Investigate container logs and health checks\nReview resource limits and application configuration')}
                END
                
                # Create consolidated restart analysis report
                IF    ${is_json}
                    ${container_summary}=    Set Variable    **Total Containers Analyzed:** ${restart_summary.get('total_containers', 0)}\n**Containers with Restarts:** ${restart_summary.get('containers_with_restarts', 0)}
                ELSE
                    ${container_summary}=    Set Variable    **Result:** ${output_text}
                END
                
                RW.Core.Add Pre To Report    **Container Restart Analysis for Deployment `${DEPLOYMENT_NAME}`**\n${container_summary}\n**Time Window:** ${CONTAINER_RESTART_AGE}\n**Restart Threshold:** ${CONTAINER_RESTART_THRESHOLD}
                
            EXCEPT
                Log    Warning: Failed to parse container restart data
                RW.Core.Add Pre To Report    **Container Restart Analysis for Deployment `${DEPLOYMENT_NAME}`**\n**Status:** Completed but results parsing failed\n\n**Raw Output:**\n${container_restarts.stdout}
            END
        END
    END

Identify Recent Configuration Changes for Deployment `${DEPLOYMENT_NAME}` in Namespace `${NAMESPACE}`
    [Documentation]    Identifies recent configuration changes from ReplicaSet analysis that might be related to current issues.
    [Tags]
    ...    configuration
    ...    changes
    ...    tracking
    ...    replicaset
    ...    deployment
    ...    analysis
    ...    access:read-only
    
    # Run configuration change analysis using bash script (matches other task patterns)
    ${config_analysis}=    RW.CLI.Run Cli
    ...    cmd=bash track_deployment_config_changes.sh "${DEPLOYMENT_NAME}" "${NAMESPACE}" "${CONTEXT}" "24h"
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    
    # Add the full analysis output to the report
    RW.Core.Add Pre To Report    **Configuration Change Analysis for Deployment `${DEPLOYMENT_NAME}`**\n\n\n${config_analysis.stdout}\n
    
    # Parse output for specific patterns and create issues if needed
    ${output}=    Set Variable    ${config_analysis.stdout}
    
    # Check for recent ReplicaSet changes
    IF    "Recent ReplicaSet change detected" in $output
        # Extract ReplicaSet information for issue creation
        ${lines}=    Split String    ${output}    \n
        ${current_rs}=    Set Variable    Unknown
        ${change_time}=    Set Variable    Unknown
        
        FOR    ${line}    IN    @{lines}
            IF    "Current ReplicaSet:" in $line
                # Extract ReplicaSet name (everything between "Current ReplicaSet: " and " (created:")
                ${rs_part}=    Evaluate    "${line}".split("Current ReplicaSet: ")[1] if len("${line}".split("Current ReplicaSet: ")) > 1 else "Unknown"
                ${current_rs}=    Evaluate    "${rs_part}".split(" (created:")[0] if " (created:" in "${rs_part}" else "${rs_part}"
                
                # Extract timestamp (everything between "(created: " and ")")
                IF    "(created: " in $line and ")" in $line
                    ${time_part}=    Evaluate    "${line}".split("(created: ")[1] if len("${line}".split("(created: ")) > 1 else "Unknown"
                    ${change_time}=    Evaluate    "${time_part}".split(")")[0] if ")" in "${time_part}" else "${time_part}"
                END
            END
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
            ...    expected=Container images should be stable for deployment `${DEPLOYMENT_NAME}` in namespace `${NAMESPACE}`
            ...    actual=Container image was updated recently for deployment `${DEPLOYMENT_NAME}` in namespace `${NAMESPACE}`
            ...    title=Recent Container Image Update Detected for Deployment `${DEPLOYMENT_NAME}`
            ...    reproduce_hint=Check ReplicaSet history for deployment `${DEPLOYMENT_NAME}` in namespace `${NAMESPACE}`
            ...    details=Configuration Change Detected\n\nChange Type: Container Image Update\nTimestamp: ${change_time}\nCurrent ReplicaSet: ${current_rs}\n\nImage Changes:\n${image_details}\nThis change may be related to current deployment issues. Verify the image update was intentional and check for known issues with the new image version.
            ...    next_steps=Verify the image update was intentional\nCheck if the new image version has known issues\nReview deployment rollout status
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
            ...    expected=Environment configuration should be stable for deployment `${DEPLOYMENT_NAME}` in namespace `${NAMESPACE}`
            ...    actual=Environment variables were modified recently for deployment `${DEPLOYMENT_NAME}` in namespace `${NAMESPACE}`
            ...    title=Recent Environment Configuration Changes Detected for Deployment `${DEPLOYMENT_NAME}`
            ...    reproduce_hint=Check ReplicaSet history for deployment `${DEPLOYMENT_NAME}` in namespace `${NAMESPACE}`
            ...    details=Configuration Change Detected\n\nChange Type: Environment Variables Update\nTimestamp: ${change_time}\nCurrent ReplicaSet: ${current_rs}\n\nEnvironment Variable Changes:\n${env_details}\nThese environment variable changes may be related to current deployment issues. Review the changes to ensure they align with expected configuration.
            ...    next_steps=Review recent environment variable changes\nVerify changes align with expected configuration\nCheck application logs for configuration-related errors
        END
        
        # Check for resource requirement changes
        IF    "Resource Requirement Changes Detected" in $output
            # Extract resource change details from output
            ${resource_details}=    Set Variable    ${EMPTY}
            ${in_resource_section}=    Set Variable    ${False}
            FOR    ${line}    IN    @{lines}
                IF    "Resource Requirement Changes Detected:" in $line
                    ${in_resource_section}=    Set Variable    ${True}
                ELSE IF    ${in_resource_section}
                    IF    "Previous resources:" in $line or "Current resources:" in $line or $line.strip().startswith("- ")
                        # Clean up emojis and format for issue details
                        ${clean_line}=    Evaluate    "${line}".replace("📊", "").strip()
                        ${resource_details}=    Set Variable    ${resource_details}${clean_line}\n
                    ELSE IF    $line.strip() == ""
                        ${in_resource_section}=    Set Variable    ${False}
                    END
                END
            END
            
            RW.Core.Add Issue
            ...    severity=4
            ...    expected=Resource limits should be stable for deployment `${DEPLOYMENT_NAME}` in namespace `${NAMESPACE}`
            ...    actual=Resource limits/requests were modified recently for deployment `${DEPLOYMENT_NAME}` in namespace `${NAMESPACE}`
            ...    title=Recent Resource Limit Changes Detected for Deployment `${DEPLOYMENT_NAME}`
            ...    reproduce_hint=Check ReplicaSet history for deployment `${DEPLOYMENT_NAME}` in namespace `${NAMESPACE}`
            ...    details=Configuration Change Detected\n\nChange Type: Resource Limits/Requests Update\nTimestamp: ${change_time}\nCurrent ReplicaSet: ${current_rs}\n\nResource Changes:\n${resource_details}\nThese resource limit changes may be related to current deployment issues. Monitor resource utilization and verify the limits are appropriate for the workload.
            ...    next_steps=Monitor resource utilization after changes\nVerify resource limits are appropriate for workload\nCheck for resource constraint issues
        END
    END
    
    # Check for kubectl apply detection
    IF    "Recent kubectl apply detected" in $output
        RW.Core.Add Issue
        ...    severity=4
        ...    expected=Deployment configuration should be synchronized for deployment `${DEPLOYMENT_NAME}` in namespace `${NAMESPACE}`
        ...    actual=Recent kubectl apply operation detected for deployment `${DEPLOYMENT_NAME}` in namespace `${NAMESPACE}`
        ...    title=Recent kubectl apply Operation Detected for Deployment `${DEPLOYMENT_NAME}`
        ...    reproduce_hint=Check deployment generation vs observed generation for `${DEPLOYMENT_NAME}` in namespace `${NAMESPACE}`
        ...    details=Recent kubectl apply operation detected. The deployment configuration has been updated but may still be processing.\n\nSee full analysis in report for generation gap details.
        ...    next_steps=Wait for controller to process changes\nCheck deployment status and conditions\nVerify no resource constraints are preventing updates
    END
    
    # Check for configuration drift
    IF    "Configuration drift detected" in $output
        RW.Core.Add Issue
        ...    severity=4
        ...    expected=Deployment configuration should be synchronized for deployment `${DEPLOYMENT_NAME}` in namespace `${NAMESPACE}`
        ...    actual=Configuration drift detected for deployment `${DEPLOYMENT_NAME}` in namespace `${NAMESPACE}`
        ...    title=Configuration Drift Detected for Deployment `${DEPLOYMENT_NAME}`
        ...    reproduce_hint=Check deployment generation vs observed generation for `${DEPLOYMENT_NAME}` in namespace `${NAMESPACE}`
        ...    details=Configuration drift detected. The deployment has been modified but the controller hasn't processed all changes yet.\n\nSee full analysis in report for drift details.
        ...    next_steps=Wait for controller to process changes\nCheck deployment status and conditions\nVerify no resource constraints are preventing updates
    END


Check HPA Health for Deployment `${DEPLOYMENT_NAME}` in Namespace `${NAMESPACE}`
    [Documentation]    Checks if a HorizontalPodAutoscaler exists for the deployment and validates its configuration and current status.
    [Tags]
    ...    hpa
    ...    autoscaling
    ...    health
    ...    deployment
    ...    ${DEPLOYMENT_NAME}
    ...    access:read-only

    # Check if HPA exists for this deployment
    ${hpa_check}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get hpa -n ${NAMESPACE} --context ${CONTEXT} -o json | jq -r '.items[] | select(.spec.scaleTargetRef.name=="${DEPLOYMENT_NAME}" and (.spec.scaleTargetRef.kind=="Deployment" or .spec.scaleTargetRef.kind=="deployment")) | .metadata.name' | head -1
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ${hpa_name}=    Strip String    ${hpa_check.stdout}

    IF    "${hpa_name}" == "" or $hpa_check.stderr != ""
        RW.Core.Add Issue
        ...    severity=4
        ...    expected=Deployment `${DEPLOYMENT_NAME}` may have HPA configured for autoscaling
        ...    actual=No HPA found for deployment `${DEPLOYMENT_NAME}` in namespace `${NAMESPACE}`
        ...    title=No HPA Found for Deployment `${DEPLOYMENT_NAME}`
        ...    reproduce_hint=Check if HPA should be configured for deployment `${DEPLOYMENT_NAME}`
        ...    details=No HorizontalPodAutoscaler was found targeting deployment ${DEPLOYMENT_NAME}. If autoscaling is needed, consider creating an HPA resource.\n\nCommand output: ${hpa_check.stdout}\nErrors: ${hpa_check.stderr}
        ...    next_steps=Evaluate if autoscaling is needed for this deployment\nCreate HPA if autoscaling is required\nReview deployment scaling patterns and resource utilization\nVerify HPA scaleTargetRef matches deployment name exactly\nCheck namespace and context are correct
        RETURN
    END

    RW.Core.Add Pre To Report    ----------\nFound HPA: ${hpa_name}

    # Get HPA details
    ${hpa_details}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get hpa ${hpa_name} -n ${NAMESPACE} --context ${CONTEXT} -o json
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}

    # Parse HPA configuration
    ${min_replicas}=    RW.CLI.Run Cli
    ...    cmd=echo '${hpa_details.stdout}' | jq -r '.spec.minReplicas // 1'
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    
    ${max_replicas}=    RW.CLI.Run Cli
    ...    cmd=echo '${hpa_details.stdout}' | jq -r '.spec.maxReplicas // "N/A"'
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    
    ${current_replicas}=    RW.CLI.Run Cli
    ...    cmd=echo '${hpa_details.stdout}' | jq -r '.status.currentReplicas // 0'
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    
    ${desired_replicas}=    RW.CLI.Run Cli
    ...    cmd=echo '${hpa_details.stdout}' | jq -r '.status.desiredReplicas // 0'
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}

    # Get metrics
    ${metrics}=    RW.CLI.Run Cli
    ...    cmd=echo '${hpa_details.stdout}' | jq -r '.spec.metrics // [] | map(.type) | join(", ")'
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}

    # Get conditions
    ${conditions}=    RW.CLI.Run Cli
    ...    cmd=echo '${hpa_details.stdout}' | jq -r '.status.conditions // [] | map("\\(.type)=\\(.status) (\\(.reason // "N/A"))") | join(", ")'
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}

    RW.Core.Add Pre To Report    ----------\nHPA Configuration:\nMin Replicas: ${min_replicas.stdout}\nMax Replicas: ${max_replicas.stdout}\nCurrent Replicas: ${current_replicas.stdout}\nDesired Replicas: ${desired_replicas.stdout}\nMetrics: ${metrics.stdout}\nConditions: ${conditions.stdout}

    # Configuration Health Checks
    
    # Check if min replicas is 1 (potential availability risk)
    ${min_is_one}=    Evaluate    int(${min_replicas.stdout}) == 1
    IF    ${min_is_one}
        RW.Core.Add Issue
        ...    severity=4
        ...    expected=HPA `${hpa_name}` should have minReplicas > 1 for high availability
        ...    actual=HPA `${hpa_name}` has minReplicas set to 1
        ...    title=HPA `${hpa_name}` May Have Availability Risk with minReplicas=1
        ...    reproduce_hint=Check HPA configuration for ${hpa_name} in namespace ${NAMESPACE}
        ...    details=HPA ${hpa_name} for deployment ${DEPLOYMENT_NAME} has minReplicas set to 1, which provides no redundancy. During scale-down periods, the deployment will have only a single replica, creating a single point of failure.\n\nCurrent: minReplicas=${min_replicas.stdout}\n\nConsider setting minReplicas to at least 2 for production workloads requiring high availability.
        ...    next_steps=Evaluate availability requirements for this deployment\nConsider increasing minReplicas to 2 or more for redundancy\nReview PodDisruptionBudget settings\nAssess impact during maintenance windows
    END

    # Check if scaling range is too narrow (max - min < 2)
    ${scaling_range}=    Evaluate    int(${max_replicas.stdout}) - int(${min_replicas.stdout})
    ${narrow_range}=    Evaluate    ${scaling_range} < 2
    IF    ${narrow_range} and int(${max_replicas.stdout}) > 0
        RW.Core.Add Issue
        ...    severity=4
        ...    expected=HPA `${hpa_name}` should have adequate scaling range
        ...    actual=HPA `${hpa_name}` has narrow scaling range (${scaling_range} replicas)
        ...    title=HPA `${hpa_name}` Has Limited Scaling Range
        ...    reproduce_hint=Check HPA configuration for ${hpa_name} in namespace ${NAMESPACE}
        ...    details=HPA ${hpa_name} for deployment ${DEPLOYMENT_NAME} has a narrow scaling range.\n\nMin: ${min_replicas.stdout}\nMax: ${max_replicas.stdout}\nRange: ${scaling_range} replicas\n\nA narrow range limits the HPA's ability to respond to load changes effectively. Consider increasing maxReplicas to provide more scaling headroom.
        ...    next_steps=Review application load patterns and scaling needs\nConsider increasing maxReplicas for better scaling flexibility\nEvaluate if HPA is appropriate for this workload\nReview metrics to understand scaling triggers
    END

    # Check if deployment has resource requests (required for CPU/memory-based HPA)
    ${resource_requests}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get deployment ${DEPLOYMENT_NAME} -n ${NAMESPACE} --context ${CONTEXT} -o json | jq -r '.spec.template.spec.containers[0].resources.requests // {} | length'
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    
    ${has_requests}=    Evaluate    int(${resource_requests.stdout}) > 0
    ${uses_resource_metrics}=    Evaluate    "Resource" in "${metrics.stdout}"
    IF    ${uses_resource_metrics} and not ${has_requests}
        RW.Core.Add Issue
        ...    severity=2
        ...    expected=Deployment `${DEPLOYMENT_NAME}` should have resource requests configured for HPA
        ...    actual=Deployment `${DEPLOYMENT_NAME}` has HPA with resource metrics but no resource requests
        ...    title=HPA `${hpa_name}` Requires Resource Requests on Deployment
        ...    reproduce_hint=Check deployment resource requests for ${DEPLOYMENT_NAME} in namespace ${NAMESPACE}
        ...    details=HPA ${hpa_name} is configured to use resource-based metrics (${metrics.stdout}), but deployment ${DEPLOYMENT_NAME} does not have resource requests defined.\n\nResource-based HPA metrics (CPU/memory utilization percentages) require containers to have resource requests configured. Without them, the HPA cannot calculate utilization percentages.
        ...    next_steps=Configure CPU and memory resource requests on deployment containers\nReview resource requirements and set appropriate requests\nConsider using absolute metrics instead of percentage-based if requests cannot be set\nVerify HPA metrics configuration matches deployment capabilities
    END

    # Check metric target values for potential misconfiguration
    ${metric_targets}=    RW.CLI.Run Cli
    ...    cmd=echo '${hpa_details.stdout}' | jq -r '.spec.metrics // [] | map(select(.type=="Resource")) | map("\\(.resource.name): \\(.resource.target.averageUtilization // .resource.target.averageValue // "N/A")%") | join(", ")'
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    
    IF    "${metric_targets.stdout}" != "" and "${metric_targets.stdout}" != "null"
        # Check for very aggressive CPU targets (< 50%)
        ${has_aggressive_cpu}=    RW.CLI.Run Cli
        ...    cmd=echo '${hpa_details.stdout}' | jq -r '.spec.metrics // [] | map(select(.type=="Resource" and .resource.name=="cpu" and (.resource.target.averageUtilization // 100) < 50)) | length'
        ...    env=${env}
        ...    secret_file__kubeconfig=${kubeconfig}
        
        ${aggressive_cpu}=    Evaluate    int(${has_aggressive_cpu.stdout}) > 0
        IF    ${aggressive_cpu}
            RW.Core.Add Issue
            ...    severity=4
            ...    expected=HPA `${hpa_name}` should have reasonable CPU targets
            ...    actual=HPA `${hpa_name}` has aggressive CPU target (< 50%)
            ...    title=HPA `${hpa_name}` Has Aggressive CPU Scaling Target
            ...    reproduce_hint=Check HPA metric targets for ${hpa_name} in namespace ${NAMESPACE}
            ...    details=HPA ${hpa_name} has a CPU utilization target below 50%, which may cause premature scaling and resource over-provisioning.\n\nMetric Targets: ${metric_targets.stdout}\n\nTypical CPU targets are 70-80% for most workloads. Very low targets can lead to excessive pod counts and wasted resources.
            ...    next_steps=Review application CPU usage patterns\nConsider raising CPU target to 70-80% range\nEvaluate if aggressive scaling is necessary for this workload\nMonitor cost implications of low utilization targets
        END

        # Check for very conservative CPU targets (> 95%)
        ${has_conservative_cpu}=    RW.CLI.Run Cli
        ...    cmd=echo '${hpa_details.stdout}' | jq -r '.spec.metrics // [] | map(select(.type=="Resource" and .resource.name=="cpu" and (.resource.target.averageUtilization // 0) > 95)) | length'
        ...    env=${env}
        ...    secret_file__kubeconfig=${kubeconfig}
        
        ${conservative_cpu}=    Evaluate    int(${has_conservative_cpu.stdout}) > 0
        IF    ${conservative_cpu}
            RW.Core.Add Issue
            ...    severity=4
            ...    expected=HPA `${hpa_name}` should have reasonable CPU targets
            ...    actual=HPA `${hpa_name}` has conservative CPU target (> 95%)
            ...    title=HPA `${hpa_name}` Has Conservative CPU Scaling Target
            ...    reproduce_hint=Check HPA metric targets for ${hpa_name} in namespace ${NAMESPACE}
            ...    details=HPA ${hpa_name} has a CPU utilization target above 95%, which may not provide sufficient headroom before scaling occurs.\n\nMetric Targets: ${metric_targets.stdout}\n\nVery high targets can lead to performance degradation before autoscaling responds. Consider lowering to 70-80% for better responsiveness.
            ...    next_steps=Review application performance during high CPU periods\nConsider lowering CPU target to 70-80% range\nMonitor response time during scale-up events\nEvaluate if conservative scaling is causing performance issues
        END
    END

    # Check for scaling behavior configuration
    ${has_behavior}=    RW.CLI.Run Cli
    ...    cmd=echo '${hpa_details.stdout}' | jq -r 'if .spec.behavior then "true" else "false" end'
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    
    IF    "${has_behavior.stdout}" == "false"
        RW.Core.Add Issue
        ...    severity=4
        ...    expected=HPA `${hpa_name}` may benefit from behavior configuration
        ...    actual=HPA `${hpa_name}` has no scaling behavior configured
        ...    title=HPA `${hpa_name}` Missing Scaling Behavior Configuration
        ...    reproduce_hint=Check HPA configuration for ${hpa_name} in namespace ${NAMESPACE}
        ...    details=HPA ${hpa_name} does not have scaling behavior configured. Scaling behavior allows fine-tuning of scale-up/scale-down rates and stabilization windows.\n\nWithout behavior configuration, HPA uses default behaviors which may not be optimal for your workload. Consider configuring:\n- Scale-up policies (how quickly to add pods)\n- Scale-down policies (how quickly to remove pods)\n- Stabilization windows (prevent flapping)
        ...    next_steps=Review HPA scaling behavior documentation\nConsider adding behavior configuration for scale-up/scale-down control\nMonitor scaling events for flapping or delayed responses\nTune stabilization windows based on application startup time
    END

    # Runtime Status Checks
    
    # Check if HPA is at max replicas (potential scaling limit)
    ${at_max}=    Evaluate    int(${current_replicas.stdout}) >= int(${max_replicas.stdout})
    IF    ${at_max} and int(${max_replicas.stdout}) > 0
        RW.Core.Add Issue
        ...    severity=3
        ...    expected=HPA `${hpa_name}` should have scaling headroom
        ...    actual=HPA `${hpa_name}` is at maximum replicas (${max_replicas.stdout})
        ...    title=HPA `${hpa_name}` at Maximum Replicas - May Need Scaling Capacity
        ...    reproduce_hint=Check HPA status for ${hpa_name} in namespace ${NAMESPACE}
        ...    details=HPA ${hpa_name} for deployment ${DEPLOYMENT_NAME} is currently at its maximum replica count (${max_replicas.stdout}). This may indicate insufficient scaling capacity to handle current load.\n\nCurrent: ${current_replicas.stdout} replicas\nMax: ${max_replicas.stdout} replicas\n\nMetrics: ${metrics.stdout}
        ...    next_steps=Review application metrics and load patterns\nConsider increasing HPA maxReplicas if more capacity is needed\nCheck if resource quotas are limiting scaling\nReview CPU/memory metrics to understand scaling triggers
    END

    # Check if HPA is at min replicas and trying to scale down (potential under-utilization)
    ${at_min}=    Evaluate    int(${current_replicas.stdout}) <= int(${min_replicas.stdout})
    ${has_min}=    Evaluate    int(${min_replicas.stdout}) > 1
    IF    ${at_min} and ${has_min}
        RW.Core.Add Issue
        ...    severity=4
        ...    expected=HPA `${hpa_name}` should scale appropriately with load
        ...    actual=HPA `${hpa_name}` is at minimum replicas (${min_replicas.stdout})
        ...    title=HPA `${hpa_name}` at Minimum Replicas - Potential Cost Optimization
        ...    reproduce_hint=Check HPA status for ${hpa_name} in namespace ${NAMESPACE}
        ...    details=HPA ${hpa_name} for deployment ${DEPLOYMENT_NAME} is at its minimum replica count (${min_replicas.stdout}). Consider reviewing if the minimum can be reduced during low-traffic periods for cost optimization.\n\nCurrent: ${current_replicas.stdout} replicas\nMin: ${min_replicas.stdout} replicas\n\nMetrics: ${metrics.stdout}
        ...    next_steps=Review application load patterns\nConsider lowering minReplicas if consistently under-utilized\nImplement time-based scaling for predictable traffic patterns\nReview resource utilization metrics
    END

    # Check for missing metrics
    IF    "${metrics.stdout}" == "" or "${metrics.stdout}" == "null"
        RW.Core.Add Issue
        ...    severity=2
        ...    expected=HPA `${hpa_name}` should have metrics configured
        ...    actual=HPA `${hpa_name}` has no metrics configured
        ...    title=HPA `${hpa_name}` Missing Metrics Configuration
        ...    reproduce_hint=Check HPA configuration for ${hpa_name} in namespace ${NAMESPACE}
        ...    details=HPA ${hpa_name} for deployment ${DEPLOYMENT_NAME} does not have any metrics configured. Without metrics, the HPA cannot make scaling decisions.\n\nCurrent configuration:\nMin: ${min_replicas.stdout}\nMax: ${max_replicas.stdout}\nMetrics: None configured
        ...    next_steps=Configure appropriate metrics for HPA (CPU, memory, or custom metrics)\nVerify metrics-server is running in the cluster\nReview HPA best practices for metric configuration
    END

    # Check for ScalingLimited condition
    ${scaling_limited}=    RW.CLI.Run Cli
    ...    cmd=echo '${hpa_details.stdout}' | jq -r '.status.conditions // [] | map(select(.type=="ScalingLimited" and .status=="True")) | length'
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    
    ${is_scaling_limited}=    Evaluate    int(${scaling_limited.stdout}) > 0
    IF    ${is_scaling_limited}
        ${limited_reason}=    RW.CLI.Run Cli
        ...    cmd=echo '${hpa_details.stdout}' | jq -r '.status.conditions // [] | map(select(.type=="ScalingLimited")) | .[0].reason // "Unknown"'
        ...    env=${env}
        ...    secret_file__kubeconfig=${kubeconfig}
        
        RW.Core.Add Issue
        ...    severity=3
        ...    expected=HPA `${hpa_name}` should be able to scale freely
        ...    actual=HPA `${hpa_name}` scaling is limited (${limited_reason.stdout})
        ...    title=HPA `${hpa_name}` Scaling Limited
        ...    reproduce_hint=Check HPA conditions for ${hpa_name} in namespace ${NAMESPACE}
        ...    details=HPA ${hpa_name} for deployment ${DEPLOYMENT_NAME} has scaling limitations.\n\nReason: ${limited_reason.stdout}\nCurrent: ${current_replicas.stdout} replicas\nMin: ${min_replicas.stdout}\nMax: ${max_replicas.stdout}\n\nThis may indicate the HPA has reached its configured limits or encountered constraints.
        ...    next_steps=Review scaling limits (min/max replicas)\nCheck if resource quotas are constraining scaling\nVerify sufficient cluster capacity exists\nReview metric targets to ensure they're appropriate
    END

    # Check for AbleToScale=False condition
    ${able_to_scale}=    RW.CLI.Run Cli
    ...    cmd=echo '${hpa_details.stdout}' | jq -r '.status.conditions // [] | map(select(.type=="AbleToScale" and .status=="False")) | length'
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    
    ${cannot_scale}=    Evaluate    int(${able_to_scale.stdout}) > 0
    IF    ${cannot_scale}
        ${unable_reason}=    RW.CLI.Run Cli
        ...    cmd=echo '${hpa_details.stdout}' | jq -r '.status.conditions // [] | map(select(.type=="AbleToScale")) | .[0].message // "Unknown reason"'
        ...    env=${env}
        ...    secret_file__kubeconfig=${kubeconfig}
        
        RW.Core.Add Issue
        ...    severity=2
        ...    expected=HPA `${hpa_name}` should be able to scale
        ...    actual=HPA `${hpa_name}` is unable to scale
        ...    title=HPA `${hpa_name}` Cannot Scale
        ...    reproduce_hint=Check HPA conditions for ${hpa_name} in namespace ${NAMESPACE}
        ...    details=HPA ${hpa_name} for deployment ${DEPLOYMENT_NAME} is unable to perform scaling operations.\n\nReason: ${unable_reason.stdout}\n\nThis typically indicates a configuration issue or missing prerequisites like metrics-server.
        ...    next_steps=Verify metrics-server is running and healthy\nCheck HPA configuration for errors\nReview deployment existence and health\nCheck RBAC permissions for HPA controller
    END

    # Add healthy status if no issues found
    ${has_issues}=    Evaluate    ${at_max} or ${is_scaling_limited} or ${cannot_scale} or ("${metrics.stdout}" == "" or "${metrics.stdout}" == "null")
    IF    not ${has_issues}
        RW.Core.Add Issue
        ...    severity=4
        ...    expected=HPA `${hpa_name}` is healthy
        ...    actual=HPA `${hpa_name}` is operating normally
        ...    title=HPA `${hpa_name}` is Healthy
        ...    reproduce_hint=Check HPA status for ${hpa_name} in namespace ${NAMESPACE}
        ...    details=HPA ${hpa_name} for deployment ${DEPLOYMENT_NAME} is healthy and operating within normal parameters.\n\nConfiguration:\nMin: ${min_replicas.stdout}\nMax: ${max_replicas.stdout}\nCurrent: ${current_replicas.stdout}\nDesired: ${desired_replicas.stdout}\nMetrics: ${metrics.stdout}
        ...    next_steps=Continue monitoring HPA metrics and scaling behavior\nReview application performance metrics\nAdjust HPA thresholds if needed based on observed patterns
    END
