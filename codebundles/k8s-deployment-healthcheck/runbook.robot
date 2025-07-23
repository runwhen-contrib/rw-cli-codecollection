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
    ...    default="errors":\s*\[\]
    ${CONTAINER_RESTART_AGE}=    RW.Core.Import User Variable    CONTAINER_RESTART_AGE
    ...    type=string
    ...    description=The time window (in (h) hours or (m) minutes) to search for container restarts. Only containers that restarted within this time period will be reported.
    ...    pattern=\w*
    ...    example=1h
    ...    default=1h
    ${CONTAINER_RESTART_THRESHOLD}=    RW.Core.Import User Variable    CONTAINER_RESTART_THRESHOLD
    ...    type=string
    ...    description=The minimum number of restarts required to trigger an issue. Containers with restart counts below this threshold will be ignored.
    ...    pattern=\d+
    ...    example=1
    ...    default=1
    # Convert comma-separated string to list
    @{LOG_PATTERN_CATEGORIES}=    Split String    ${LOG_PATTERN_CATEGORIES_STR}    ,
    
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
    [Documentation]    Fetches and analyzes logs from the deployment pods for errors, stack traces, connection issues, and other patterns that indicate application health problems.
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
        ${log_dir}=    RW.K8sLog.Fetch Workload Logs
        ...    workload_type=deployment
        ...    workload_name=${DEPLOYMENT_NAME}
        ...    namespace=${NAMESPACE}
        ...    context=${CONTEXT}
        ...    kubeconfig=${kubeconfig}
        ...    log_age=${LOG_AGE}
        
        ${scan_results}=    RW.K8sLog.Scan Logs For Issues
        ...    log_dir=${log_dir}
        ...    workload_type=deployment
        ...    workload_name=${DEPLOYMENT_NAME}
        ...    namespace=${NAMESPACE}
        ...    categories=@{LOG_PATTERN_CATEGORIES}
        
        # Post-process results to filter out patterns matching LOGS_EXCLUDE_PATTERN
        TRY
            IF    "${LOGS_EXCLUDE_PATTERN}" != ""
                ${filtered_issues}=    Evaluate    [issue for issue in $scan_results.get('issues', []) if not __import__('re').search(r'${LOGS_EXCLUDE_PATTERN}', issue.get('details', ''), __import__('re').IGNORECASE)]    modules=re
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
                ${summarized_details}=    RW.K8sLog.Summarize Log Issues    issue_details=${issue["details"]}
                RW.Core.Add Issue
                ...    severity=${severity}
                ...    expected=Application logs should be free of critical errors for deployment `${DEPLOYMENT_NAME}` in namespace `${NAMESPACE}`
                ...    actual=${issue.get('title', 'Log pattern issue detected')} in deployment `${DEPLOYMENT_NAME}` in namespace `${NAMESPACE}`
                ...    title=${issue.get('title', 'Log Pattern Issue')} in Deployment `${DEPLOYMENT_NAME}`
                ...    reproduce_hint=Check application logs for deployment `${DEPLOYMENT_NAME}` in namespace `${NAMESPACE}`
                ...    details=${summarized_details}
                ...    next_steps=${issue.get('next_steps', 'Review application logs and resolve underlying issues')}
            END
        END

        ${issues_count}=    Get Length    ${issues}
        
        # Format scan results for better display
        ${formatted_results}=    RW.K8sLog.Format Scan Results For Display    scan_results=${scan_results}
        
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

Perform Comprehensive Log Analysis for Deployment `${DEPLOYMENT_NAME}` in Namespace `${NAMESPACE}`
    [Documentation]    Performs in-depth log analysis including security events, resource warnings, connectivity issues, and application lifecycle problems.
    [Tags]
    ...    logs
    ...    comprehensive
    ...    security
    ...    resources
    ...    connectivity
    ...    deployment
    ...    access:read-only
    # Skip pod-related checks if deployment is scaled to 0
    IF    not ${SKIP_POD_CHECKS}
        # Only run comprehensive analysis if depth is set to comprehensive
        IF    '${LOG_ANALYSIS_DEPTH}' == 'comprehensive'
            ${comprehensive_results}=    RW.CLI.Run Bash File
            ...    bash_file=deployment_logs.sh
            ...    env=${env}
            ...    secret_file__kubeconfig=${kubeconfig}
            ...    include_in_history=false
            
            IF    ${comprehensive_results.returncode} != 0
                RW.Core.Add Issue
                ...    severity=3
                ...    expected=Comprehensive log analysis should complete successfully for deployment `${DEPLOYMENT_NAME}` in namespace `${NAMESPACE}`
                ...    actual=Failed to perform comprehensive log analysis for deployment `${DEPLOYMENT_NAME}` in namespace `${NAMESPACE}`
                ...    title=Comprehensive Log Analysis Failed for Deployment `${DEPLOYMENT_NAME}`
                ...    reproduce_hint=${comprehensive_results.cmd}
                ...    details=Comprehensive analysis failed with exit code ${comprehensive_results.returncode}:\n\nSTDOUT:\n${comprehensive_results.stdout}\n\nSTDERR:\n${comprehensive_results.stderr}
                ...    next_steps=Verify log collection is working properly\nCheck if pods are accessible and generating logs\nReview comprehensive analysis script configuration
            ELSE
                RW.Core.Add Pre To Report    **Comprehensive Log Analysis Results for Deployment `${DEPLOYMENT_NAME}`**\n\n${comprehensive_results.stdout}
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
    ${events}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get events --context ${CONTEXT} -n ${NAMESPACE} -o json | jq '(now - (60*60*3)) as $time_limit | [ .items[] | select(.type == "Warning" and (.involvedObject.kind == "Deployment" or .involvedObject.kind == "Pod" or .involvedObject.kind == "ReplicaSet") and (.involvedObject.name | tostring | contains("${DEPLOYMENT_NAME}")) and (.lastTimestamp // empty | if . then fromdateiso8601 else 0 end) >= $time_limit) | {kind: .involvedObject.kind, name: .involvedObject.name, reason: .reason, message: .message, firstTimestamp: .firstTimestamp, lastTimestamp: .lastTimestamp, count: .count} ] | group_by([.kind, .name]) | map(if length > 0 then {kind: .[0].kind, name: .[0].name, total_count: (map(.count // 1) | add), reasons: (map(.reason) | unique), messages: (map(.message) | unique), firstTimestamp: (map(.firstTimestamp // empty | if . then fromdateiso8601 else 0 end) | sort | .[0] | if . > 0 then todateiso8601 else null end), lastTimestamp: (map(.lastTimestamp // empty | if . then fromdateiso8601 else 0 end) | sort | reverse | .[0] | if . > 0 then todateiso8601 else null end)} else empty end) | map(. + {summary: "\(.kind) \(.name): \(.total_count) events (\(.reasons | join(", ")))"}) | {events_summary: map(.summary), total_objects: length, events: .}'
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
        # Collect ALL events (Normal + Warning) for last 3 hours including Deployment, ReplicaSet, and Pod levels
        ${all_events}=    RW.CLI.Run Cli
        ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get events --context ${CONTEXT} -n ${NAMESPACE} -o json | jq --argjson hours 3 '(now - ($hours * 3600)) as $time_limit | [.items[] | select((.involvedObject.kind == "Deployment" or .involvedObject.kind == "Pod" or .involvedObject.kind == "ReplicaSet") and (.involvedObject.name | tostring | contains("${DEPLOYMENT_NAME}")) and (.lastTimestamp // empty | if . then fromdateiso8601 else now end) >= $time_limit)] | sort_by(.lastTimestamp // .firstTimestamp) | {total_events: length, normal_events: (map(select(.type == "Normal")) | length), warning_events: (map(select(.type == "Warning")) | length), deployment_events: (map(select(.involvedObject.kind == "Deployment")) | length), replicaset_events: (map(select(.involvedObject.kind == "ReplicaSet")) | length), pod_events: (map(select(.involvedObject.kind == "Pod")) | length), events_by_type: (group_by(.type) | map({type: .[0].type, count: length, reasons: (map(.reason) | group_by(.) | map({reason: .[0], count: length}))})), chronological_events: (map({timestamp: (.lastTimestamp // .firstTimestamp), type: .type, kind: .involvedObject.kind, name: .involvedObject.name, reason: .reason, message: .message}) | sort_by(.timestamp)), recent_warnings: (map(select(.type == "Warning")) | map({timestamp: (.lastTimestamp // .firstTimestamp), kind: .involvedObject.kind, name: .involvedObject.name, reason: .reason, message: .message}) | sort_by(.timestamp) | reverse | .[0:10])}'
        ...    env=${env}
        ...    secret_file__kubeconfig=${kubeconfig}
        ...    include_in_history=false
        
        TRY
            ${event_data}=    Evaluate    json.loads(r'''${all_events.stdout}''') if r'''${all_events.stdout}'''.strip() else {}    json
            ${warning_count}=    Evaluate    $event_data.get('warning_events', 0)
            ${total_count}=    Evaluate    $event_data.get('total_events', 0)
            
            # Build comprehensive event report
            RW.Core.Add Pre To Report    **📊 Complete Event Summary for Deployment `${DEPLOYMENT_NAME}` (Last 3 Hours)**\n**Total Events:** ${total_count} (${event_data.get('normal_events', 0)} Normal, ${event_data.get('warning_events', 0)} Warning)\n**Event Distribution:** ${event_data.get('deployment_events', 0)} Deployment, ${event_data.get('replicaset_events', 0)} ReplicaSet, ${event_data.get('pod_events', 0)} Pod
            
            IF    ${warning_count} > 0
                ${event_object_data}=    Evaluate    json.loads(r'''${events.stdout}''') if r'''${events.stdout}'''.strip() else {}    json
                ${object_list}=    Evaluate    $event_object_data.get('events', [])
                
                # Check if deployment is currently scaled to 0 to filter stale events
                ${deployment_scaled_down}=    Set Variable    ${SKIP_POD_CHECKS}
                
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
                        
                        # Skip stale pod events if deployment is scaled down
                        ${skip_stale_event}=    Set Variable    ${False}
                        IF    ${deployment_scaled_down} and '${item["kind"]}' == 'Pod'
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
                                        ${updated_issue}=    Evaluate    {**$existing_issue, 'count': ${updated_count}, 'affected_objects': "${updated_objects}"}
                                        ${updated_dict}=    Evaluate    {**$consolidated_issues, "${issue_key}": $updated_issue}
                                        Set Test Variable    ${consolidated_issues}    ${updated_dict}
                                    ELSE
                                        ${new_issue}=    Evaluate    {**$issue, 'count': 1, 'affected_objects': "${item["kind"]}/${item["name"]}, "}
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
                        
                        IF    ${count} > 1
                            ${title_suffix}=    Set Variable    (${count} objects affected)
                            ${details_prefix}=    Set Variable    **Affected Objects (${count}):** ${affected_objects}\n\n
                        ELSE
                            ${title_suffix}=    Set Variable    ${EMPTY}
                            ${details_prefix}=    Set Variable    **Affected Object:** ${affected_objects}\n\n
                        END
                        
                        RW.Core.Add Issue
                        ...    severity=${issue["severity"]}
                        ...    expected=No warning events should be present for deployment `${DEPLOYMENT_NAME}` in namespace `${NAMESPACE}`
                        ...    actual=${issue["title"]} detected for deployment `${DEPLOYMENT_NAME}` in namespace `${NAMESPACE}`
                        ...    title=${issue["title"]} in Deployment `${DEPLOYMENT_NAME}` ${title_suffix}
                        ...    reproduce_hint=${events.cmd}
                        ...    details=${details_prefix}${issue["details"]}
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
                ...    title=Deployment `${DEPLOYMENT_NAME}` is Missing ${missing_replicas} Ready Replicas
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
                
                # Check if output looks like JSON (starts with { or [)
                ${is_json}=    Evaluate    $output_text.startswith(('{', '[')) if $output_text else False
                
                IF    ${is_json}
                    ${restart_data}=    Evaluate    json.loads(r'''${container_restarts.stdout}''')    json
                    ${restart_issues}=    Evaluate    $restart_data.get('issues', [])
                    ${restart_summary}=    Evaluate    $restart_data.get('summary', {})
                ELSE
                    # Handle plain text response (no restarts found)
                    ${restart_data}=    Create Dictionary    issues=@{EMPTY}    summary=@{EMPTY}
                    ${restart_issues}=    Create List
                    ${restart_summary}=    Create Dictionary    total_containers=0    containers_with_restarts=0
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