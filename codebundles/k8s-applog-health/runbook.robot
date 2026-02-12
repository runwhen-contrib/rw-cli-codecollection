*** Settings ***
Documentation       Triages issues related to a deployment and its replicas.
Metadata            Author    akshayrw25
Metadata            Display Name    Kubernetes AppLog Analysis
Metadata            Supports    Kubernetes,AKS,EKS,GKE,OpenShift

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             RW.NextSteps
Library             RW.K8sHelper
Library             RW.K8sLog
Library             RW.LogAnalysis.ExtractTraceback

Library             OperatingSystem
Library             String
Library             Collections
Library             DateTime

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
    ${WORKLOAD_NAME}=    RW.Core.Import User Variable    WORKLOAD_NAME
    ...    type=string
    ...    description=The name of the workload (deployment, statefulset, or daemonset) to analyze for application logs.
    ...    pattern=\w*
    ...    example=otel-demo-frontend
    ${WORKLOAD_TYPE}=    RW.Core.Import User Variable    WORKLOAD_TYPE
    ...    type=string
    ...    description=The type of Kubernetes workload to analyze.
    ...    pattern=\w*
    ...    enum=[deployment,statefulset,daemonset]
    ...    example=deployment
    ...    default=deployment
    ${LOG_LINES}=    RW.Core.Import User Variable    LOG_LINES
    ...    type=string
    ...    description=The number of log lines to fetch from the pods when inspecting logs.
    ...    pattern=\d+
    ...    example=100
    ...    default=1000
    ${LOG_AGE}=    RW.Core.Import User Variable    LOG_AGE
    ...    type=string
    ...    description=The age of logs to fetch from pods, used for log analysis tasks.
    ...    pattern=\w*
    ...    example=10m
    ...    default=10m
    ${LOG_SIZE}=    RW.Core.Import User Variable    LOG_SIZE
    ...    type=string
    ...    description=The maximum size of logs in bytes to fetch from pods, used for log analysis tasks. Defaults to 2MB.
    ...    pattern=\d*
    ...    example=1024
    ...    default=2097152

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
    ...    example=GenericError,AppFailure,Connection
    ...    default=GenericError,AppFailure,Connection,Timeout,Auth,Exceptions,Resource,HealthyRecovery
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
    ...    example="errors":\\s*\\[\\]|"warnings":\\s*\\[\\]
    ...    default="errors":\\\\s*\\\\[\\\\]|\\\\bINFO\\\\b|\\\\bDEBUG\\\\b|\\\\bTRACE\\\\b|\\\\bSTART\\\\s*-\\\\s*|\\\\bSTART\\\\s*method\\\\b
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
    Set Suite Variable    ${WORKLOAD_NAME}
    Set Suite Variable    ${WORKLOAD_TYPE}
    Set Suite Variable    ${LOG_LINES}
    Set Suite Variable    ${LOG_AGE}
    Set Suite Variable    ${LOG_SIZE}

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
    ...    WORKLOAD_NAME=${WORKLOAD_NAME}
    ...    WORKLOAD_TYPE=${WORKLOAD_TYPE}
    ...    CONTAINER_RESTART_AGE=${CONTAINER_RESTART_AGE}
    ...    CONTAINER_RESTART_THRESHOLD=${CONTAINER_RESTART_THRESHOLD}
    ...    LOG_SCAN_TIMEOUT=${LOG_SCAN_TIMEOUT}
    Set Suite Variable    ${env}    ${env_dict}
    
    # Check if workload is scaled to 0 and handle appropriately
    # Different workload types have different field structures
    
    IF    '${WORKLOAD_TYPE}' == 'daemonset'
        # DaemonSets don't scale to 0 in the traditional sense, so skip scale-down logic for them
        Log    ${WORKLOAD_TYPE} ${WORKLOAD_NAME} is a DaemonSet - proceeding with log checks
        Set Suite Variable    ${SKIP_HEALTH_CHECKS}    ${False}
    ELSE
        IF    '${WORKLOAD_TYPE}' == 'statefulset'
            # StatefulSet: use current/updated replicas in addition to spec/ready
            ${scale_check}=    RW.CLI.Run Cli
            ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get ${WORKLOAD_TYPE}/${WORKLOAD_NAME} --context ${CONTEXT} -n ${NAMESPACE} -o json | jq '{spec_replicas: .spec.replicas, ready_replicas: (.status.readyReplicas // 0), current_replicas: (.status.currentReplicas // 0), updated_replicas: (.status.updatedReplicas // 0)}'
            ...    env=${env}
            ...    secret_file__kubeconfig=${kubeconfig}
            ...    timeout_seconds=30
        ELSE
            # For deployments
            ${scale_check}=    RW.CLI.Run Cli
            ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get ${WORKLOAD_TYPE}/${WORKLOAD_NAME} --context ${CONTEXT} -n ${NAMESPACE} -o json | jq '{spec_replicas: .spec.replicas, ready_replicas: (.status.readyReplicas // 0), available_condition: (.status.conditions[] | select(.type == "Available") | .status // "Unknown")}'
            ...    env=${env}
            ...    secret_file__kubeconfig=${kubeconfig}
            ...    timeout_seconds=30
        END
        
        TRY
            ${scale_status}=    Evaluate    json.loads(r'''${scale_check.stdout}''') if r'''${scale_check.stdout}'''.strip() else {}    json
            ${spec_replicas}=    Evaluate    $scale_status.get('spec_replicas', 1)

            # Try to determine when deployment was scaled down by checking recent events and replica set history
            ${scale_down_info}=    Get Deployment Scale Down Timestamp    ${spec_replicas}
            
            IF    ${spec_replicas} == 0
                Log    ${WORKLOAD_TYPE} ${WORKLOAD_NAME} is scaled to 0 replicas - returning special health score
                Log    Scale down detected at: ${scale_down_info}
                
                # For scaled-down workloads, return a score of 1.0 to indicate "intentionally down" vs "broken"
                Set Suite Variable    ${SKIP_HEALTH_CHECKS}    ${True}
                Set Suite Variable    ${SCALED_DOWN_INFO}    ${scale_down_info}
            ELSE
                Log    ${WORKLOAD_TYPE} ${WORKLOAD_NAME} has ${spec_replicas} desired replicas - proceeding with log checks
                Set Suite Variable    ${SKIP_HEALTH_CHECKS}    ${False}
            END
            
        EXCEPT
            Log    Warning: Failed to check workload scale, continuing with normal log checks
            Set Suite Variable    ${SKIP_HEALTH_CHECKS}    ${False}
        END
    END


*** Tasks ***


Analyze Application Log Patterns for ${WORKLOAD_TYPE} `${WORKLOAD_NAME}` in Namespace `${NAMESPACE}`
    [Documentation]    Fetches and analyzes logs from the deployment pods for errors, connection issues, and other patterns that indicate application health problems. Note: Warning messages about missing log files for excluded containers (like linkerd-proxy, istio-proxy) are expected and harmless.
    [Tags]
    ...    logs
    ...    application
    ...    errors
    ...    patterns
    ...    health
    ...    ${WORKLOAD_TYPE}
    ...    access:read-only
    # Skip pod-related checks if deployment is scaled to 0
    IF    not ${SKIP_HEALTH_CHECKS}
        # Temporarily suppress log warnings for excluded containers (they're expected)
        TRY
            ${log_dir}=    RW.K8sLog.Fetch Workload Logs
            ...    workload_type=${WORKLOAD_TYPE}
            ...    workload_name=${WORKLOAD_NAME}
            ...    namespace=${NAMESPACE}
            ...    context=${CONTEXT}
            ...    kubeconfig=${kubeconfig}
            ...    log_age=${LOG_AGE}
            ...    excluded_containers=${EXCLUDED_CONTAINERS}
        EXCEPT    AS    ${log_error}
            # If log fetching fails completely, log the error but continue
            Log    Warning: Log fetching encountered an error: ${log_error}

            # TODO: remove this after testing
            RW.Core.Add Pre To Report    **Log Fetching Error:** ${log_error}
            # Set empty log directory to continue with other checks
            ${log_dir}=    Set Variable    ${EMPTY}
        END
        
        # Only scan logs if we have a valid log directory
        IF    '''${log_dir}''' != '''${EMPTY}'''
            ${scan_results}=    RW.K8sLog.Scan Logs For Issues
            ...    log_dir=${log_dir}
            ...    workload_type=${WORKLOAD_TYPE}
            ...    workload_name=${WORKLOAD_NAME}
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
                
                # Use timestamp from log scan results if available, otherwise extract from details
                ${issue_timestamp}=    Evaluate    $issue.get('observed_at', '')

                RW.Core.Add Issue
                ...    severity=${severity}
                ...    expected=Application logs should be free of critical errors for ${WORKLOAD_TYPE} `${WORKLOAD_NAME}` in namespace `${NAMESPACE}`
                ...    actual=${issue_title} in ${WORKLOAD_TYPE} `${WORKLOAD_NAME}` in namespace `${NAMESPACE}`
                ...    title=${issue_title} in ${WORKLOAD_TYPE} `${WORKLOAD_NAME}`
                ...    reproduce_hint=Check application logs for ${WORKLOAD_TYPE} `${WORKLOAD_NAME}` in namespace `${NAMESPACE}`
                ...    details=${summarized_details}
                ...    next_steps=${next_steps}
                ...    observed_at=${issue_timestamp}
                ...    next_action=analyzeApplog
            END
        END

        ${issues_count}=    Get Length    ${issues}
        
        # Convert scan_results to string to avoid serialization issues, then format for display
        ${scan_results_str}=    Evaluate    json.dumps($scan_results, indent=2)    json
        ${formatted_results}=    RW.K8sLog.Format Scan Results For Display    scan_results=${scan_results_str}
        
        RW.Core.Add Pre To Report    **Log Analysis Summary for ${WORKLOAD_TYPE} `${WORKLOAD_NAME}` in Namespace `${NAMESPACE}` (Last ${LOG_LINES} lines, ${LOG_AGE} age) **\n**Health Score:** ${log_health_score}\n**Analysis Depth:** ${LOG_ANALYSIS_DEPTH}\n**Categories Analyzed:** ${LOG_PATTERN_CATEGORIES_STR}\n**Issues Found:** ${issues_count}\n\n${formatted_results}
        
        RW.K8sLog.Cleanup Temp Files
    END

Fetch Workload Logs for `${WORKLOAD_TYPE}` `${WORKLOAD_NAME}` in Namespace `${NAMESPACE}`
    [Documentation]    Fetches and displays workload logs in the report for manual review. Note: Issues are not created by this task - see "Analyze Application Log Patterns" for automated issue detection.
    [Tags]
    ...    logs
    ...    collection
    ...    ${WORKLOAD_TYPE}
    ...    troubleshooting
    ...    access:read-only
    # Skip pod-related checks if deployment is scaled to 0
    IF    not ${SKIP_HEALTH_CHECKS}
        # Fetch raw logs
        ${workload_logs}=    RW.CLI.Run Cli
        ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} logs ${WORKLOAD_TYPE}/${WORKLOAD_NAME} --context ${CONTEXT} -n ${NAMESPACE} --tail=${LOG_LINES} --since=${LOG_AGE}
        ...    env=${env}
        ...    secret_file__kubeconfig=${kubeconfig}
        ...    show_in_rwl_cheatsheet=true
        ...    render_in_commandlist=true
        
        IF    ${workload_logs.returncode} == 0
            # Filter logs to remove repetitive health check messages and focus on meaningful content
            ${filtered_logs}=    RW.CLI.Run Cli
            ...    cmd=echo "${workload_logs.stdout}" | grep -v -E "(Checking.*Health|Health.*Check|healthcheck|/health|GET /|POST /health|probe|liveness|readiness)" | grep -E "(error|ERROR|warn|WARN|exception|Exception|fail|FAIL|fatal|FATAL|panic|stack|trace|timeout|connection.*refused|unable.*connect|authentication.*failed|denied|forbidden|unauthorized|500|502|503|504)" | tail -50 || echo "No significant errors or warnings found in recent logs"
            ...    env=${env}
            ...    include_in_history=false
            
            # Also get a sample of non-health-check logs for context
            ${context_logs}=    RW.CLI.Run Cli
            ...    cmd=echo "${workload_logs.stdout}" | grep -v -E "(Checking.*Health|Health.*Check|healthcheck|/health|GET /|POST /health|probe|liveness|readiness)" | head -20 | tail -10
            ...    env=${env}
            ...    include_in_history=false
            
            ${history}=    RW.CLI.Pop Shell History
            
            # Determine if logs are mostly health checks
            ${total_lines}=    RW.CLI.Run Cli
            ...    cmd=echo "${workload_logs.stdout}" | wc -l
            ...    env=${env}
            ...    include_in_history=false
            
            ${health_check_lines}=    RW.CLI.Run Cli
            ...    cmd=echo "${workload_logs.stdout}" | grep -E "(Checking.*Health|Health.*Check|healthcheck|/health)" | wc -l
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
                RW.Core.Add Pre To Report    **📋 Raw Workload Logs for `${WORKLOAD_TYPE}` `${WORKLOAD_NAME}`** (Last ${LOG_LINES} lines, ${LOG_AGE} age)\n**Total Log Lines:** ${total_count} | **Health Check Lines:** ${health_count}\n**ℹ️ Logs are mostly health check messages (${health_count}/${total_count} lines)**\n\n${log_content}\n\n**Commands Used:** ${history}\n\n**Note:** Automated issue detection is performed by the "Analyze Application Log Patterns" task.
            ELSE
                RW.Core.Add Pre To Report    **📋 Raw Workload Logs for `${WORKLOAD_TYPE}` `${WORKLOAD_NAME}`** (Last ${LOG_LINES} lines, ${LOG_AGE} age)\n**Total Log Lines:** ${total_count} | **Health Check Lines:** ${health_count}\n\n**📝 Recent Application Logs:**\n${workload_logs.stdout}\n\n**Commands Used:** ${history}\n\n**Note:** Automated issue detection is performed by the "Analyze Application Log Patterns" task.
            END
        ELSE
            # Only add to report if fetch failed, don't create issue
            ${history}=    RW.CLI.Pop Shell History
            RW.Core.Add Pre To Report    **📋 Raw Logs for `${WORKLOAD_TYPE}` `${WORKLOAD_NAME}`**\n\n⚠️ Unable to fetch workload logs (exit code ${workload_logs.returncode}).\n\n**STDERR:** ${workload_logs.stderr}\n\n**Commands Used:** ${history}
        END
    END


Analyze Workload Stacktraces for ${WORKLOAD_TYPE} `${WORKLOAD_NAME}` in Namespace `${NAMESPACE}`
    [Documentation]    Collects and analyzes stacktraces/tracebacks from all pods in the workload for troubleshooting application issues.
    [Tags]
    ...    logs
    ...    stacktraces
    ...    tracebacks
    ...    ${WORKLOAD_TYPE}
    ...    troubleshooting
    ...    errors
    ...    access:read-only
    # Skip pod-related checks if workload is scaled to 0
    IF    not ${SKIP_HEALTH_CHECKS}
        # Convert comma-separated string to list for excluded containers
        @{EXCLUDED_CONTAINERS}=    Run Keyword If    "${EXCLUDED_CONTAINER_NAMES}" != ""    Split String    ${EXCLUDED_CONTAINER_NAMES}    ,    ELSE    Create List
        
        # Fetch logs using RW.K8sLog library (same pattern as deployment healthcheck)
        ${log_dir}=    RW.K8sLog.Fetch Workload Logs
        ...    workload_type=${WORKLOAD_TYPE}
        ...    workload_name=${WORKLOAD_NAME}
        ...    namespace=${NAMESPACE}
        ...    context=${CONTEXT}
        ...    kubeconfig=${kubeconfig}
        ...    log_age=${LOG_AGE}
        ...    max_log_lines=${LOG_LINES}
        ...    max_log_bytes=${LOG_SIZE}
        ...    excluded_containers=${EXCLUDED_CONTAINERS}
        
        # Extract stacktraces from the log directory using the traceback library
        ${tracebacks}=    RW.LogAnalysis.ExtractTraceback.Extract Tracebacks
        ...    logs_dir=${log_dir}
        
        # Check total number of tracebacks extracted
        ${total_tracebacks}=    Get Length    ${tracebacks}
        
        IF    ${total_tracebacks} == 0
            # No tracebacks found
            RW.Core.Add Pre To Report    **📋 No Stacktraces Found for ${WORKLOAD_TYPE} `${WORKLOAD_NAME}` in Namespace `${NAMESPACE}`**\n**Log Analysis Period:** ${LOG_AGE}\n**Max Log Lines:** ${LOG_LINES}\n**Max Log Size:** ${LOG_SIZE} bytes\n**Excluded Containers:** ${EXCLUDED_CONTAINER_NAMES}\n\nLog analysis completed successfully with no stacktraces detected.
        ELSE            
            # Stacktraces found - create issues for each one
            ${delimiter}=    Evaluate    '-' * 80
            
            FOR    ${traceback}    IN    @{tracebacks}
                ${stacktrace}=    Set Variable    ${traceback["stacktrace"]}
                ${timestamp}=    Set Variable    ${traceback["timestamp"]}
                RW.Core.Add Issue
                ...    severity=2
                ...    expected=No stacktraces should be present in ${WORKLOAD_TYPE} `${WORKLOAD_NAME}` logs in namespace `${NAMESPACE}`
                ...    actual=Stacktrace detected in ${WORKLOAD_TYPE} `${WORKLOAD_NAME}` logs in namespace `${NAMESPACE}`
                ...    title=Stacktrace Detected in ${WORKLOAD_TYPE} `${WORKLOAD_NAME}`
                ...    reproduce_hint=Check application logs for ${WORKLOAD_TYPE} `${WORKLOAD_NAME}` in namespace `${NAMESPACE}`
                ...    details=${delimiter}\n${stacktrace}\n${delimiter}
                ...    next_steps=Review application logs for the root cause of the stacktrace\nCheck application configuration and resource limits\nInvestigate the specific error conditions that led to this stacktrace\nConsider scaling or restarting the ${WORKLOAD_TYPE} if issues persist\nMonitor application health and performance metrics
                ...    next_action=analyseStacktrace
                ...    observed_at=${timestamp}
            END
            
            # Create consolidated report showing all stacktraces
            ${stacktrace_strings}=    Evaluate    [tb["stacktrace"] for tb in ${tracebacks}]
            ${agg_tracebacks}=    Evaluate    "\\n" + "\\n${delimiter}\\n".join(${stacktrace_strings})
            RW.Core.Add Pre To Report    **🔍 Stacktraces Found for ${WORKLOAD_TYPE} `${WORKLOAD_NAME}` in Namespace `${NAMESPACE}`**\n**Total Stacktraces:** ${total_tracebacks}\n**Log Analysis Period:** ${LOG_AGE}\n**Max Log Lines:** ${LOG_LINES}\n**Max Log Size:** ${LOG_SIZE} bytes\n**Excluded Containers:** ${EXCLUDED_CONTAINER_NAMES}\n\n${agg_tracebacks}
        END
        
        # Clean up temporary log files
        RW.K8sLog.Cleanup Temp Files
    END
