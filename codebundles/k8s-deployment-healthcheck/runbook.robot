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
    ...    description=Pattern used to exclude entries from log results when searching in log results.
    ...    pattern=\w*
    ...    example=(node_modules|opentelemetry)
    ...    default=info    
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
    Set Suite Variable    @{LOG_PATTERN_CATEGORIES}
    Set Suite Variable    ${ANOMALY_THRESHOLD}
    Set Suite Variable    ${LOGS_ERROR_PATTERN}
    Set Suite Variable    ${LOGS_EXCLUDE_PATTERN}
    Set Suite Variable
    ...    ${env}
    ...    {"KUBECONFIG":"./${kubeconfig.key}", "KUBERNETES_DISTRIBUTION_BINARY":"${KUBERNETES_DISTRIBUTION_BINARY}", "CONTEXT":"${CONTEXT}", "NAMESPACE":"${NAMESPACE}", "LOGS_ERROR_PATTERN":"${LOGS_ERROR_PATTERN}", "LOGS_EXCLUDE_PATTERN":"${LOGS_EXCLUDE_PATTERN}", "ANOMALY_THRESHOLD":"${ANOMALY_THRESHOLD}", "DEPLOYMENT_NAME": "${DEPLOYMENT_NAME}"}


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
    
    ${log_health_score}=    RW.K8sLog.Calculate Log Health Score    scan_results=${scan_results}
    
    # Process each issue found in the logs
    ${issues}=    Evaluate    $scan_results.get('issues', [])
    IF    len($issues) > 0
        FOR    ${issue}    IN    @{issues}
            ${summarized_details}=    RW.K8sLog.Summarize Log Issues    issue_details=${issue["details"]}
            ${next_steps_text}=    Catenate    SEPARATOR=\n    @{issue["next_steps"]}
            
            RW.Core.Add Issue
            ...    severity=${issue["severity"]}
            ...    expected=No application errors should be present in deployment `${DEPLOYMENT_NAME}` logs in namespace `${NAMESPACE}`
            ...    actual=Application errors detected in deployment `${DEPLOYMENT_NAME}` logs in namespace `${NAMESPACE}`
            ...    title=${issue["title"]}
            ...    reproduce_hint=Use RW.K8sLog.Fetch Workload Logs and RW.K8sLog.Scan Logs For Issues keywords to reproduce this analysis
            ...    details=${summarized_details}
            ...    next_steps=${next_steps_text}
        END
    END
    
    # Add summary to report
    ${summary_text}=    Catenate    SEPARATOR=\n    @{scan_results["summary"]}
    RW.Core.Add Pre To Report    Application Log Analysis Summary for Deployment ${DEPLOYMENT_NAME}:\n${summary_text}
    RW.Core.Add Pre To Report    Log Health Score: ${log_health_score} (1.0 = healthy, 0.0 = unhealthy)
    
    RW.K8sLog.Cleanup Temp Files

Detect Log Anomalies for Deployment `${DEPLOYMENT_NAME}` in Namespace `${NAMESPACE}`
    [Documentation]    Analyzes logs for repeating patterns, anomalous behavior, and unusual log volume that may indicate underlying issues.
    [Tags]
    ...    logs
    ...    anomalies
    ...    patterns
    ...    volume
    ...    deployment
    ...    ${DEPLOYMENT_NAME}
    ...    access:read-only
    ${log_dir}=    RW.K8sLog.Fetch Workload Logs
    ...    workload_type=deployment
    ...    workload_name=${DEPLOYMENT_NAME}
    ...    namespace=${NAMESPACE}
    ...    context=${CONTEXT}
    ...    kubeconfig=${kubeconfig}
    ...    log_age=${LOG_AGE}
    
    ${anomaly_results}=    RW.K8sLog.Analyze Log Anomalies
    ...    log_dir=${log_dir}
    ...    workload_type=deployment
    ...    workload_name=${DEPLOYMENT_NAME}
    ...    namespace=${NAMESPACE}
    
    # Process anomaly issues
    ${anomaly_issues}=    Evaluate    $anomaly_results.get('issues', [])
    IF    len($anomaly_issues) > 0
        FOR    ${issue}    IN    @{anomaly_issues}
            ${summarized_details}=    RW.K8sLog.Summarize Log Issues    issue_details=${issue["details"]}
            ${next_steps_text}=    Catenate    SEPARATOR=\n    @{issue["next_steps"]}
            
            RW.Core.Add Issue
            ...    severity=${issue["severity"]}
            ...    expected=No log anomalies should be present in deployment `${DEPLOYMENT_NAME}` in namespace `${NAMESPACE}`
            ...    actual=Log anomalies detected in deployment `${DEPLOYMENT_NAME}` in namespace `${NAMESPACE}`
            ...    title=${issue["title"]}
            ...    reproduce_hint=Use RW.K8sLog.Analyze Log Anomalies keyword to reproduce this analysis
            ...    details=${summarized_details}
            ...    next_steps=${next_steps_text}
        END
    END
    
    # Add summary to report
    ${anomaly_summary}=    Catenate    SEPARATOR=\n    @{anomaly_results["summary"]}
    RW.Core.Add Pre To Report    Log Anomaly Analysis for Deployment ${DEPLOYMENT_NAME}:\n${anomaly_summary}
    
    RW.K8sLog.Cleanup Temp Files

Check Deployment Log For Issues with `${DEPLOYMENT_NAME}`
    [Documentation]    Comprehensive log analysis with pattern detection, Kubernetes event correlation, and actionable insights. Combines modern pattern matching with lnav-powered analysis for deep log investigation.
    [Tags]
    ...    logs
    ...    errors
    ...    analysis
    ...    events
    ...    correlation
    ...    deployment
    ...    ${DEPLOYMENT_NAME}
    ...    access:read-only
    
    # Fetch and analyze logs using K8sLog library
    ${log_dir}=    RW.K8sLog.Fetch Workload Logs
    ...    workload_type=deployment
    ...    workload_name=${DEPLOYMENT_NAME}
    ...    namespace=${NAMESPACE}
    ...    context=${CONTEXT}
    ...    kubeconfig=${kubeconfig}
    ...    log_age=3h
    
    # Pattern-based analysis with configurable categories
    ${categories_by_depth}=    Run Keyword If    '${LOG_ANALYSIS_DEPTH}' == 'basic'
    ...    Create List    GenericError    AppFailure    StackTrace
    ...    ELSE IF    '${LOG_ANALYSIS_DEPTH}' == 'comprehensive'
    ...    Create List    GenericError    AppFailure    StackTrace    Connection    Timeout    Auth    Exceptions    Anomaly    AppRestart    Resource
    ...    ELSE
    ...    Create List    GenericError    AppFailure    StackTrace    Connection    Timeout    Auth    Exceptions    Resource
    
    ${scan_results}=    RW.K8sLog.Scan Logs For Issues
    ...    log_dir=${log_dir}
    ...    workload_type=deployment
    ...    workload_name=${DEPLOYMENT_NAME}
    ...    namespace=${NAMESPACE}
    ...    categories=${categories_by_depth}
    
    # Run original deployment_logs.sh for lnav analysis and event correlation
    ${legacy_analysis}=    RW.CLI.Run Bash File
    ...    bash_file=deployment_logs.sh 
    ...    cmd_override=./deployment_logs.sh | tee "legacy_log_analysis"
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    timeout_seconds=180
    ...    include_in_history=false
    
    # Extract legacy recommendations and event correlations
    ${legacy_recommendations}=    RW.CLI.Run Cli
    ...    cmd=awk "/Recommended Next Steps:/ {start=1; getline} start" "legacy_log_analysis"
    ...    env=${env}
    ...    include_in_history=false
    
    ${legacy_issues}=    RW.CLI.Run Cli
    ...    cmd=awk '/Issues Identified:/ {start=1; next} /The namespace `${NAMESPACE}` has produced the following interesting events:/ {start=0} start' "legacy_log_analysis"
    ...    env=${env}
    ...    include_in_history=false
    
    ${event_correlations}=    RW.CLI.Run Cli
    ...    cmd=awk '/The namespace.*has produced the following interesting events:/ {start=1; next} start' "legacy_log_analysis"
    ...    env=${env}
    ...    include_in_history=false
    
    # Process pattern-based issues with severity filtering
    ${issues}=    Evaluate    $scan_results.get('issues', [])
    ${actionable_issues}=    Create List
    ${warning_events}=    Create List
    ${info_findings}=    Create List
    
    # Filter issues by severity threshold and categorize
    FOR    ${issue}    IN    @{issues}
        IF    ${issue["severity"]} <= ${LOG_SEVERITY_THRESHOLD}
            Append To List    ${actionable_issues}    ${issue}
        ELSE
            Append To List    ${info_findings}    ${issue}
        END
    END
    
    # Create issues for actionable problems
    FOR    ${issue}    IN    @{actionable_issues}
        ${summarized_details}=    RW.K8sLog.Summarize Log Issues    issue_details=${issue["details"]}
        ${next_steps_text}=    Catenate    SEPARATOR=\n    @{issue["next_steps"]}
        
        # Add legacy recommendations if available
        ${enhanced_next_steps}=    Set Variable If    len($legacy_recommendations.stdout.strip()) > 0
        ...    ${next_steps_text}\n\n**Additional Context:**\n${legacy_recommendations.stdout}
        ...    ${next_steps_text}
        
        RW.Core.Add Issue
        ...    severity=${issue["severity"]}
        ...    expected=No ${issue.get("category", "log")} errors should be present in deployment `${DEPLOYMENT_NAME}` in namespace `${NAMESPACE}`
        ...    actual=${issue.get("category", "Log")} errors detected in deployment `${DEPLOYMENT_NAME}` in namespace `${NAMESPACE}`
        ...    title=[${issue.get("category", "Unknown")}] ${issue["title"]}
        ...    reproduce_hint=Use RW.K8sLog keywords or run deployment_logs.sh to reproduce this analysis
        ...    details=**Pattern Category:** ${issue.get("category", "Unknown")}\n**Severity Level:** ${issue["severity"]}\n\n${summarized_details}
        ...    next_steps=${enhanced_next_steps}
    END
    
    # Create issue for legacy-detected problems if any
    IF    len($legacy_issues.stdout.strip()) > 0
        RW.Core.Add Issue
        ...    severity=3
        ...    expected=No log anomalies or resource correlation issues in deployment `${DEPLOYMENT_NAME}` in namespace `${NAMESPACE}`
        ...    actual=Log anomalies or resource correlations detected in deployment `${DEPLOYMENT_NAME}` in namespace `${NAMESPACE}`
        ...    title=[Legacy Analysis] Log Pattern and Resource Correlation Issues
        ...    reproduce_hint=Run deployment_logs.sh script to reproduce this analysis
        ...    details=**Legacy lnav Analysis Results:**\n${legacy_issues.stdout}\n\n**Event Correlations:**\n${event_correlations.stdout}
        ...    next_steps=${legacy_recommendations.stdout}
    END
    
    # Generate actionable metrics summary
    ${total_issues}=    Evaluate    len($actionable_issues)
    ${critical_count}=    Evaluate    len([i for i in $actionable_issues if i['severity'] <= 2])
    ${warning_count}=    Evaluate    len([i for i in $actionable_issues if i['severity'] == 3])
    ${info_count}=    Evaluate    len($info_findings)
    
    # Create issues categories breakdown
    ${category_counts}=    Create Dictionary
    FOR    ${issue}    IN    @{actionable_issues}
        ${category}=    Set Variable    ${issue.get("category", "Unknown")}
        ${current_count}=    Evaluate    $category_counts.get("${category}", 0)
        ${new_count}=    Evaluate    ${current_count} + 1
        ${updated_counts}=    Evaluate    {**$category_counts, "${category}": ${new_count}}
        Set Test Variable    ${category_counts}    ${updated_counts}
    END
    
    # Enhanced report with actionable metrics
    RW.Core.Add Pre To Report    🔍 **Log Analysis Results for Deployment ${DEPLOYMENT_NAME}**
    RW.Core.Add Pre To Report    **Analysis Period:** 3 hours | **Analysis Depth:** ${LOG_ANALYSIS_DEPTH} | **Severity Threshold:** ${LOG_SEVERITY_THRESHOLD}
    RW.Core.Add Pre To Report    \n**📊 Issue Breakdown:**
    RW.Core.Add Pre To Report    • **Actionable Issues:** ${total_issues} (${critical_count} critical, ${warning_count} warnings)
    RW.Core.Add Pre To Report    • **Informational Findings:** ${info_count} (below severity threshold)
    ${legacy_status}=    Set Variable If    len($legacy_analysis.stdout.strip()) > 0    ✅ Completed    ❌ Failed
    RW.Core.Add Pre To Report    • **Legacy Analysis:** ${legacy_status}
    ${event_status}=    Set Variable If    len($event_correlations.stdout.strip()) > 0    ✅ Available    ℹ️ None found
    RW.Core.Add Pre To Report    • **Event Correlation:** ${event_status}
    
    # Category breakdown
    IF    len($category_counts) > 0
        ${category_summary}=    Create List
        FOR    ${category}    IN    @{category_counts.keys()}
            ${count}=    Evaluate    $category_counts["${category}"]
            Append To List    ${category_summary}    • **${category}:** ${count} issues
        END
        ${category_text}=    Catenate    SEPARATOR=\n    @{category_summary}
        RW.Core.Add Pre To Report    \n**📋 Issues by Category:**\n${category_text}
    END
    
    # Detailed findings summary
    ${summary_text}=    Catenate    SEPARATOR=\n    @{scan_results["summary"]}
    RW.Core.Add Pre To Report    \n**🔍 Pattern Analysis Summary:**\n${summary_text}
    
    # Legacy analysis integration
    IF    len($legacy_analysis.stdout.strip()) > 0
        RW.Core.Add Pre To Report    \n**🧬 Advanced Log Analysis (lnav + Event Correlation):**
        RW.Core.Add Pre To Report    ${legacy_analysis.stdout}
    END
    
    # Informational findings (not issues, but useful context)
    IF    len($info_findings) > 0
        ${info_summary}=    Create List
        FOR    ${finding}    IN    @{info_findings}
            Append To List    ${info_summary}    • **${finding["title"]}** (${finding.get("category", "Unknown")}): ${finding.get("summary", "No summary available")}
        END
        ${info_text}=    Catenate    SEPARATOR=\n    @{info_summary}
        RW.Core.Add Pre To Report    \n**ℹ️ Additional Findings (Below Severity Threshold):**\n${info_text}
    END
    
    RW.K8sLog.Cleanup Temp Files

Fetch Deployments Logs for `${DEPLOYMENT_NAME}` in Namespace `${NAMESPACE}` and Add to Report
    [Documentation]    Fetches logs from running pods and adds content to the report
    [Tags]
    ...    kubernetes
    ...    deployment
    ...    logs
    ...    deployment
    ...    ${DEPLOYMENT_NAME}
    ...    access:read-only
    ${logs}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} logs deployment/${DEPLOYMENT_NAME} -n ${NAMESPACE} --tail=${LOG_LINES} --all-containers=true --max-log-requests=20 --context ${CONTEXT}
    ...    env=${env}
    ...    include_in_history=true
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    timeout_seconds=180
    ...    show_in_rwl_cheatsheet=true
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Commands Used: ${history}
    RW.Core.Add Pre To Report
    ...    Recent logs from Deployment ${DEPLOYMENT_NAME} in Namespace ${NAMESPACE}:\n\n${logs.stdout}

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
    ...    access:read-only
    ${liveness_probe_health}=    RW.CLI.Run Bash File
    ...    bash_file=validate_probes.sh
    ...    cmd_override=./validate_probes.sh livenessProbe | tee "liveness_probe_output"
    ...    env=${env}
    ...    include_in_history=False
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    show_in_rwl_cheatsheet=true
    ${recommendations}=    RW.CLI.Run Cli
    ...    cmd=awk '/Recommended Next Steps:/ {flag=1; next} flag' "liveness_probe_output"
    ...    env=${env}
    ...    include_in_history=false
    IF    len($recommendations.stdout) > 0
        RW.Core.Add Issue
        ...    severity=2
        ...    expected=Liveness probes should be configured and functional for deployment `${DEPLOYMENT_NAME}` in namespace `${NAMESPACE}`
        ...    actual=Issues found with liveness probe configuration for Deployment `${DEPLOYMENT_NAME}` in namespace `${NAMESPACE}`
        ...    title=Configuration Issues with Deployment `${DEPLOYMENT_NAME}` in namespace `${NAMESPACE}`
        ...    reproduce_hint=View Commands Used in Report Output
        ...    details=Liveness Probe Configuration Issues with Deployment ${DEPLOYMENT_NAME}\n${liveness_probe_health.stdout}
        ...    next_steps=${recommendations.stdout}
    END
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Liveness probe testing results:\n\n${liveness_probe_health.stdout}
    RW.Core.Add Pre To Report    Commands Used: ${liveness_probe_health.cmd}

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
    ${readiness_probe_health}=    RW.CLI.Run Bash File
    ...    bash_file=validate_probes.sh
    ...    cmd_override=./validate_probes.sh readinessProbe | tee "readiness_probe_output"
    ...    env=${env}
    ...    include_in_history=False
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    show_in_rwl_cheatsheet=true
    ${recommendations}=    RW.CLI.Run Cli
    ...    cmd=awk '/Recommended Next Steps:/ {flag=1; next} flag' "readiness_probe_output"
    ...    env=${env}
    ...    include_in_history=false
    IF    len($recommendations.stdout) > 0
        RW.Core.Add Issue
        ...    severity=2
        ...    expected=Readiness probes should be configured and functional for deployment `${DEPLOYMENT_NAME}` in namespace `${NAMESPACE}`
        ...    actual=Issues found with readiness probe configuration for Deployment `${DEPLOYMENT_NAME}` in namespace `${NAMESPACE}`
        ...    title=Configuration Issues with Deployment `${DEPLOYMENT_NAME}` in namespace `${NAMESPACE}`
        ...    reproduce_hint=View Commands Used in Report Output
        ...    details=Readiness Probe Issues with Deployment ${DEPLOYMENT_NAME}\n${readiness_probe_health.stdout}
        ...    next_steps=${recommendations.stdout}
    END
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Readiness probe testing results:\n\n${readiness_probe_health.stdout}
    RW.Core.Add Pre To Report    Commands Used: ${readiness_probe_health.cmd}

Inspect Container Restarts for Deployment `${DEPLOYMENT_NAME}` in Namespace `${NAMESPACE}`
    [Documentation]    Fetches pods that have container restarts and provides a report of the restart issues.
    [Tags]    access:read-only  namespace    containers    status    restarts    ${DEPLOYMENT_NAME}    ${NAMESPACE}
    ${container_restart_analysis}=    RW.CLI.Run Bash File
    ...    bash_file=container_restarts.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    include_in_history=False
    ${recommendations}=    RW.CLI.Run Cli
    ...    cmd=echo '${container_restart_analysis.stdout}' | awk '/Recommended Next Steps:/ {flag=1; next} flag'
    ...    env=${env}
    ...    include_in_history=false
    IF    $recommendations.stdout != ""
        TRY
            ${recommendation_list}=    Evaluate    json.loads(r'''${recommendations.stdout}''')    json
        EXCEPT
            Log    Warning: Failed to parse container restart JSON, creating generic issue
            ${recommendation_list}=    Create List
        END
        
        IF    len(@{recommendation_list}) > 0
            FOR    ${item}    IN    @{recommendation_list}
                RW.Core.Add Issue
                ...    severity=${item["severity"]}
                ...    expected=Containers should not be restarting for Deployment `${DEPLOYMENT_NAME}` in namespace `${NAMESPACE}`
                ...    actual=We found containers with restarts for Deployment `${DEPLOYMENT_NAME}` in namespace `${NAMESPACE}`
                ...    title=${item["title"]}
                ...    reproduce_hint=${container_restart_analysis.cmd}
                ...    details=${item["details"]}
                ...    next_steps=${item["next_steps"]}
            END
        ELSE IF    "restart" in $recommendations.stdout.lower()
            # Create generic issue if we detect restart content but parsing failed
            RW.Core.Add Issue
            ...    severity=3
            ...    expected=Containers should not be restarting for Deployment `${DEPLOYMENT_NAME}` in namespace `${NAMESPACE}`
            ...    actual=Container restart issues detected for Deployment `${DEPLOYMENT_NAME}` in namespace `${NAMESPACE}`
            ...    title=Container Restart Issues Detected for Deployment `${DEPLOYMENT_NAME}`
            ...    reproduce_hint=${container_restart_analysis.cmd}
            ...    details=Container restart analysis output:\n${recommendations.stdout}
            ...    next_steps=Review container restart analysis and investigate pod restart causes
        END
    END
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Summary of container restarts for Deployment `${DEPLOYMENT_NAME}` in namespace: ${NAMESPACE}
    RW.Core.Add Pre To Report    ${container_restart_analysis.stdout}
    RW.Core.Add Pre To Report    Commands Used:\n${history}

Inspect Deployment Warning Events for `${DEPLOYMENT_NAME}` in Namespace `${NAMESPACE}`
    [Documentation]    Fetches warning events related to the deployment workload in the namespace and triages any issues found in the events.
    [Tags]    access:read-only  events    workloads    errors    warnings    get    deployment    ${DEPLOYMENT_NAME}
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
            ...    expected=No warning events should be present for Deployment `${DEPLOYMENT_NAME}` in namespace `${NAMESPACE}`
            ...    actual=Warning events detected for Deployment `${DEPLOYMENT_NAME}` in namespace `${NAMESPACE}`
            ...    title=Warning Events Detected for Deployment `${DEPLOYMENT_NAME}` (Parse Failed)
            ...    reproduce_hint=${events.cmd}
            ...    details=Warning events detected but JSON parsing failed. Raw output:\n${events.stdout}
            ...    next_steps=Manually review events output and investigate warning conditions\n${related_resource_recommendations}
        END
    END
    
    # Consolidate issues by type to avoid duplicates
    ${pod_issues}=    Create List
    ${deployment_issues}=    Create List
    ${unique_issue_types}=    Create Dictionary
    
    IF    len(@{object_list}) > 0
        FOR    ${item}    IN    @{object_list}
            ${message_string}=    Catenate    SEPARATOR;    @{item["messages"]}
            ${messages}=    RW.K8sHelper.Sanitize Messages    ${message_string}
            ${issues}=    RW.CLI.Run Bash File
            ...    bash_file=workload_issues.sh
            ...    cmd_override=./workload_issues.sh "${messages}" "Deployment" "${DEPLOYMENT_NAME}"
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
                    Append To List    ${deployment_issues}    ${issue}
                END
            END
            
            # If no structured issues but we have event content, create generic issue
            IF    len(@{issue_list}) == 0 and len($messages) > 0
                ${generic_issue}=    Create Dictionary    
                ...    severity=3    
                ...    title=Event Issues for ${item["kind"]} ${item["name"]}    
                ...    next_steps=Investigate event messages: ${messages}    
                ...    details=Event detected but issue parsing failed: ${messages}
                
                IF    '${item["kind"]}' == 'Pod'
                    Append To List    ${pod_issues}    ${generic_issue}
                ELSE
                    Append To List    ${deployment_issues}    ${generic_issue}
                END
            END
        END
        
        # Create consolidated issues
        IF    len($pod_issues) > 0
            # Group pod issues by type and create single consolidated issue
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
            ...    expected=Pod readiness and health should be maintained for Deployment `${DEPLOYMENT_NAME}` in namespace `${NAMESPACE}`
            ...    actual=${pod_count} pods are experiencing issues for Deployment `${DEPLOYMENT_NAME}` in namespace `${NAMESPACE}`
            ...    title=Multiple Pod Issues for Deployment `${DEPLOYMENT_NAME}` (${pod_count} pods affected)
            ...    reproduce_hint=${events.cmd}
            ...    details=**Affected Pods:** ${pod_count}\n\n${consolidated_pod_details}
            ...    next_steps=${sample_pod_issue["next_steps"]}\n${related_resource_recommendations}
        END
        
        # Create issues for deployment/replicaset level problems (should be fewer)
        ${processed_deployment_titles}=    Create Dictionary
        FOR    ${issue}    IN    @{deployment_issues}
            ${title_key}=    Set Variable    ${issue["title"]}
            ${is_duplicate}=    Evaluate    $processed_deployment_titles.get("${title_key}", False)
            IF    not ${is_duplicate}
                ${updated_titles}=    Evaluate    {**$processed_deployment_titles, "${title_key}": True}
                Set Test Variable    ${processed_deployment_titles}    ${updated_titles}
                RW.Core.Add Issue
                ...    severity=${issue["severity"]}
                ...    expected=No deployment-level warning events should be present for Deployment `${DEPLOYMENT_NAME}` in namespace `${NAMESPACE}`
                ...    actual=Deployment-level warning events found for Deployment `${DEPLOYMENT_NAME}` in namespace `${NAMESPACE}`
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

Fetch Deployment Workload Details For `${DEPLOYMENT_NAME}` in Namespace `${NAMESPACE}`
    [Documentation]    Fetches the current state of the deployment for future review in the report.
    [Tags]    access:read-only  deployment    details    manifest    info    ${DEPLOYMENT_NAME}
    ${deployment}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get deployment/${DEPLOYMENT_NAME} --context ${CONTEXT} -n ${NAMESPACE} -o yaml
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    show_in_rwl_cheatsheet=true
    ...    render_in_commandlist=true
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Snapshot of deployment state:\n\n${deployment.stdout}
    RW.Core.Add Pre To Report    Commands Used: ${history}

Inspect Deployment Replicas for `${DEPLOYMENT_NAME}` in namespace `${NAMESPACE}`
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
    ...    access:read-only
    ${deployment_replicas}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get deployment/${DEPLOYMENT_NAME} --context ${CONTEXT} -n ${NAMESPACE} -o json | jq '.status | {desired_replicas: .replicas, ready_replicas: (.readyReplicas // 0), missing_replicas: ((.replicas // 0) - (.readyReplicas // 0)), unavailable_replicas: (.unavailableReplicas // 0), available_condition: (if any(.conditions[]; .type == "Available") then (.conditions[] | select(.type == "Available")) else "Condition not available" end), progressing_condition: (if any(.conditions[]; .type == "Progressing") then (.conditions[] | select(.type == "Progressing")) else "Condition not available" end)}'
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    env=${env}
    ...    show_in_rwl_cheatsheet=true
    ...    render_in_commandlist=true
    TRY
        ${deployment_status}=    Evaluate    json.loads(r'''${deployment_replicas.stdout}''') if r'''${deployment_replicas.stdout}'''.strip() else {}    json
    EXCEPT
        Log    Warning: Failed to parse deployment status JSON, using empty status
        ${deployment_status}=    Create Dictionary
    END
    
    # Set safe defaults for missing keys
    ${available_condition}=    Evaluate    $deployment_status.get('available_condition', {'status': 'Unknown', 'message': 'Status unavailable'})
    ${ready_replicas}=    Evaluate    $deployment_status.get('ready_replicas', 0)
    ${desired_replicas}=    Evaluate    $deployment_status.get('desired_replicas', 0)
    ${unavailable_replicas}=    Evaluate    $deployment_status.get('unavailable_replicas', 0)
    ${progressing_condition}=    Evaluate    $deployment_status.get('progressing_condition', {'status': 'Unknown'})
    
    IF    "${available_condition['status']}" == "False" or ${ready_replicas} == 0
        ${item_next_steps}=    RW.CLI.Run Bash File
        ...    bash_file=workload_next_steps.sh
        ...    cmd_override=./workload_next_steps.sh "${available_condition['message']}" "Deployment" "${DEPLOYMENT_NAME}"
        ...    env=${env}
        ...    include_in_history=False
        RW.Core.Add Issue
        ...    severity=1
        ...    expected=Deployment `${DEPLOYMENT_NAME}` in namespace `${NAMESPACE}` should have minimum availability / pod.
        ...    actual=Deployment `${DEPLOYMENT_NAME}` in namespace `${NAMESPACE}` does not have minimum availability / pods.
        ...    title=Deployment `${DEPLOYMENT_NAME}` in Namespace `${NAMESPACE}` is unavailable
        ...    reproduce_hint=View Commands Used in Report Output
        ...    details=Deployment `${DEPLOYMENT_NAME}` has ${ready_replicas} ready pods and needs ${desired_replicas}
        ...    next_steps=${item_next_steps.stdout}
    ELSE IF    ${unavailable_replicas} > 0 and "${available_condition['status']}" == "True" and "${progressing_condition['status']}" == "False"
        RW.Core.Add Issue
        ...    severity=3
        ...    expected=Deployment `${DEPLOYMENT_NAME}` in namespace `${NAMESPACE}` should have ${desired_replicas} pods.
        ...    actual=Deployment `${DEPLOYMENT_NAME}` in namespace `${NAMESPACE}` has ${ready_replicas} pods.
        ...    title=Deployment `${DEPLOYMENT_NAME}` has Missing Replicas in Namespace `${NAMESPACE}`
        ...    reproduce_hint=View Commands Used in Report Output
        ...    details=Deployment `${DEPLOYMENT_NAME}` has ${ready_replicas} ready pods but needs ${desired_replicas}
        ...    next_steps=Check pod status and investigate why replicas are not ready
    END