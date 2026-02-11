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
    
    # Check if the workload is scaled to 0 and handle appropriately
    ${scale_check}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get ${WORKLOAD_TYPE}/${WORKLOAD_NAME} --context ${CONTEXT} -n ${NAMESPACE} -o json | jq '{spec_replicas: .spec.replicas, ready_replicas: (.status.readyReplicas // 0), available_condition: (.status.conditions[] | select(.type == "Available") | .status // "Unknown")}'
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    timeout_seconds=30
    
    TRY
        ${scale_status}=    Evaluate    json.loads(r'''${scale_check.stdout}''') if r'''${scale_check.stdout}'''.strip() else {}    json
        ${spec_replicas}=    Evaluate    $scale_status.get('spec_replicas', 1)
        
        # DaemonSets don't scale to 0 in the traditional sense, so skip scale-down logic for them
        IF    '${WORKLOAD_TYPE}' == 'daemonset'
            Log    ${WORKLOAD_TYPE} ${WORKLOAD_NAME} is a DaemonSet - proceeding with log analysis
            Set Suite Variable    ${SKIP_POD_CHECKS}    ${False}
        ELSE IF    ${spec_replicas} == 0
            RW.Core.Add Issue
            ...    severity=4
            ...    expected=${WORKLOAD_TYPE} `${WORKLOAD_NAME}` operational status documented
            ...    actual=${WORKLOAD_TYPE} `${WORKLOAD_NAME}` is intentionally scaled to zero replicas
            ...    title=${WORKLOAD_TYPE} `${WORKLOAD_NAME}` is Scaled Down (Informational)
            ...    reproduce_hint=kubectl get ${WORKLOAD_TYPE}/${WORKLOAD_NAME} --context ${CONTEXT} -n ${NAMESPACE} -o yaml
            ...    details=${WORKLOAD_TYPE} `${WORKLOAD_NAME}` is currently scaled to 0 replicas (spec.replicas=0). This is an intentional configuration and not an error. All pod-related healthchecks have been skipped for efficiency. If the workload should be running, scale it up using:\nkubectl scale ${WORKLOAD_TYPE}/${WORKLOAD_NAME} --replicas=<desired_count> --context ${CONTEXT} -n ${NAMESPACE}
            ...    next_steps=This is informational only. If the workload should be running, scale it up.
            
            RW.Core.Add Pre To Report    **ℹ️ ${WORKLOAD_TYPE} `${WORKLOAD_NAME}` is scaled to 0 replicas - Skipping log analysis**\n**Available Condition:** ${scale_status.get('available_condition', 'Unknown')}
            
            Set Suite Variable    ${SKIP_POD_CHECKS}    ${True}
        ELSE
            Set Suite Variable    ${SKIP_POD_CHECKS}    ${False}
        END
        
    EXCEPT
        Log    Warning: Failed to check workload scale, continuing with normal checks
        Set Suite Variable    ${SKIP_POD_CHECKS}    ${False}
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
    IF    not ${SKIP_POD_CHECKS}
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
            END
        END

        ${issues_count}=    Get Length    ${issues}
        
        # Convert scan_results to string to avoid serialization issues, then format for display
        ${scan_results_str}=    Evaluate    json.dumps($scan_results, indent=2)    json
        ${formatted_results}=    RW.K8sLog.Format Scan Results For Display    scan_results=${scan_results_str}
        
        RW.Core.Add Pre To Report    **Log Analysis Summary for ${WORKLOAD_TYPE} `${WORKLOAD_NAME}`**\n**Health Score:** ${log_health_score}\n**Analysis Depth:** ${LOG_ANALYSIS_DEPTH}\n**Categories Analyzed:** ${LOG_PATTERN_CATEGORIES_STR}\n**Issues Found:** ${issues_count}\n\n${formatted_results}
        
        RW.K8sLog.Cleanup Temp Files
    END