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
            ${issue_timestamp}=    DateTime.Get Current Date
            RW.Core.Add Issue
            ...    severity=4
            ...    expected=Deployment `${DEPLOYMENT_NAME}` operational status documented
            ...    actual=Deployment `${DEPLOYMENT_NAME}` is intentionally scaled to zero replicas
            ...    title=Deployment `${DEPLOYMENT_NAME}` is Scaled Down (Informational)
            ...    reproduce_hint=kubectl get deployment/${DEPLOYMENT_NAME} --context ${CONTEXT} -n ${NAMESPACE} -o yaml
            ...    details=Deployment `${DEPLOYMENT_NAME}` is currently scaled to 0 replicas (spec.replicas=0). This is an intentional configuration and not an error. All pod-related healthchecks have been skipped for efficiency. If the deployment should be running, scale it up using:\nkubectl scale deployment/${DEPLOYMENT_NAME} --replicas=<desired_count> --context ${CONTEXT} -n ${NAMESPACE}
            ...    next_steps=This is informational only. If the deployment should be running, scale it up.
            ...    observed_at=${issue_timestamp}
            
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

Scan Application Logs for Errors and Stacktraces for Deployment `${DEPLOYMENT_NAME}` in Namespace `${NAMESPACE}`
    [Documentation]    Fetches and analyzes logs from the deployment pods for stacktraces, errors, connection issues, and other patterns that indicate application health problems. Note: Warning messages about missing log files for excluded containers (like linkerd-proxy, istio-proxy) are expected and harmless.
    [Tags]
    ...    logs
    ...    application
    ...    errors
    ...    stacktrace
    ...    patterns
    ...    health
    ...    deployment
    ...    access:read-only
    # Skip pod-related checks if deployment is scaled to 0
    IF    not ${SKIP_POD_CHECKS}
        # record current time, and use if no issues found
        ${log_extraction_timestamp}=    DateTime.Get Current Date
        
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
        ${issues_count}=    Get Length    ${issues}

        # print the contents from log_dir into the report
        ${logs_subdir}=    Set Variable    ${log_dir}${/}deployment_${DEPLOYMENT_NAME}_logs
        ${has_logs_dir}=    Run Keyword And Return Status    Directory Should Exist    ${logs_subdir}

        IF    ${has_logs_dir}
            @{log_files}=    List Files In Directory    ${logs_subdir}    pattern=*_logs.txt    absolute=True
            Sort List    ${log_files}

            RW.Core.Add Pre To Report    **Log Contents (showing last ${LOG_LINES} lines per file)**

            FOR    ${log_file}    IN    @{log_files}
                ${base}=    Evaluate    __import__('os').path.basename(r'''${log_file}''')

                # Efficient-ish tail in Python: keeps only last N lines
                ${tail}=    Evaluate    ''.join(__import__('collections').deque(open(r'''${log_file}''', 'r', encoding='utf-8', errors='replace'), maxlen=int('${LOG_LINES}')))

                RW.Core.Add Pre To Report    [LOG_START: ${base}]\n${tail}\n[LOG_END: ${base}]\n
            END
        ELSE
            RW.Core.Add Pre To Report    **Log Contents:**\nNo log files directory found at: ${logs_subdir}
        END

        IF    ${issues_count} == 0
            ${issue_timestamp}=    Set Variable    ${log_extraction_timestamp}
            
            # create a dummy issue with a keyword argument set to a value depicting no issues found
            RW.Core.Add Pre To Report    **No issues found in application logs for deployment `${DEPLOYMENT_NAME}` in namespace `${NAMESPACE}`**
            
            # create a dummy issue with a keyword argument set to a value depicting no issues found
            RW.Core.Add Issue
            ...    severity=4
            ...    expected=Application logs should be free of critical errors for deployment `${DEPLOYMENT_NAME}` in namespace `${NAMESPACE}`
            ...    actual=No issues found in application logs for deployment `${DEPLOYMENT_NAME}` in namespace `${NAMESPACE}`
            ...    title=No issues found in application logs for deployment `${DEPLOYMENT_NAME}` in namespace `${NAMESPACE}`
            ...    reproduce_hint=Check application logs for deployment `${DEPLOYMENT_NAME}` in namespace `${NAMESPACE}`
            ...    details=No issues found in application logs for deployment `${DEPLOYMENT_NAME}` in namespace `${NAMESPACE}`
            ...    next_steps=No processing required
            ...    observed_at=${issue_timestamp}
            ...    next_action=noIssuesFound
        ELSE
            # set issue_timestamp to the observed_at value from the first issue
            ${issue_timestamp}=    Evaluate    $issues[0].get('observed_at', '')
            
            # create a dummy issue with a keyword argument set to a value depicting issues found
            RW.Core.Add Issue
            ...    severity=4
            ...    expected=Application logs should be free of critical errors for deployment `${DEPLOYMENT_NAME}` in namespace `${NAMESPACE}`
            ...    actual=Issues found in application logs for deployment `${DEPLOYMENT_NAME}` in namespace `${NAMESPACE}`
            ...    title=Issues found in application logs for deployment `${DEPLOYMENT_NAME}` in namespace `${NAMESPACE}`
            ...    reproduce_hint=Check application logs for deployment `${DEPLOYMENT_NAME}` in namespace `${NAMESPACE}`
            ...    details=Issues found in application logs for deployment `${DEPLOYMENT_NAME}` in namespace `${NAMESPACE}`
            ...    next_steps=Process the issues found in the application logs
            ...    observed_at=${issue_timestamp}
            ...    next_action=processApplogIssues
        END        
        RW.K8sLog.Cleanup Temp Files
    END