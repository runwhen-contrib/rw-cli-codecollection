*** Settings ***
Documentation       Troubleshooting and remediation tasks for GCP Vertex AI Model Garden using Google Cloud Monitoring Python SDK.
Metadata            Author    stewartshea
Metadata            Display Name    GCP Vertex AI Model Garden Health
Metadata            Supports    GCP,Vertex AI,Model Garden

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             OperatingSystem
Library             Collections
Library             DateTime
Library             String

Suite Setup         Suite Initialization

*** Tasks ***
Discover All Deployed Vertex AI Models in `${GCP_PROJECT_ID}`
    [Documentation]    Discovers all deployed Vertex AI models across regions to establish baseline for subsequent analysis
    [Tags]    vertex-ai    discovery    models    endpoints    access:read-only    data:config
    
    # Run comprehensive model discovery once
    ${discovery_check}=    RW.CLI.Run Cli
    ...    cmd=python3 vertex_ai_monitoring.py discover ${region_args}
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    show_in_rwl_cheatsheet=true
    ...    timeout_seconds=300
    
    # Extract key metrics for subsequent tasks
    ${models_discovered}=    Set Variable    0
    ${endpoints_discovered}=    Set Variable    0
    
    @{discovery_lines}=    Split String    ${discovery_check.stdout}    \n
    FOR    ${line}    IN    @{discovery_lines}
        ${line}=    Strip String    ${line}
        IF    'ALL_MODELS_DISCOVERED:' in $line
            ${count_part}=    Split String    ${line}    :
            ${models_discovered}=    Strip String    ${count_part}[1]
            ${models_discovered}=    Convert To Number    ${models_discovered}
        ELSE IF    'ALL_ENDPOINTS_DISCOVERED:' in $line
            ${count_part}=    Split String    ${line}    :
            ${endpoints_discovered}=    Strip String    ${count_part}[1]
            ${endpoints_discovered}=    Convert To Number    ${endpoints_discovered}
        END
    END
    
    # Set global variables for other tasks to use
    Set Global Variable    ${DISCOVERED_MODELS}    ${models_discovered}
    Set Global Variable    ${DISCOVERED_ENDPOINTS}    ${endpoints_discovered}
    
    ${consolidated_report}=    Catenate    SEPARATOR=\n
    ...    🔍 VERTEX AI MODEL DISCOVERY REPORT
    ...    ═══════════════════════════════════════════════════════
    ...    📊 Summary: ${models_discovered} models deployed across ${endpoints_discovered} endpoints
    ...    ${EMPTY}
    ...    🔍 Full Discovery Results:
    ...    ${discovery_check.stdout}
    ...    ${EMPTY}
    ...    Command Used: ${discovery_check.cmd}
    
    RW.Core.Add Pre To Report    ${consolidated_report}
    
    # Create issue if no models found
    IF    ${models_discovered} == 0
        RW.Core.Add Issue    
        ...    title=No Vertex AI models discovered    
        ...    severity=2    
        ...    expected=At least one deployed model should be found    
        ...    actual=No models found across all checked regions    
        ...    reproduce_hint=Run: python3 vertex_ai_monitoring.py discover    
        ...    details=The discovery process checked common regions (us-central1, us-east4, us-east5, europe-west4, asia-southeast1) but found no deployed models    
        ...    next_steps=Verify models are deployed in your project and check if they're in regions not scanned. Deploy models if none exist.
    END

Analyze Vertex AI Model Garden Error Patterns and Response Codes in `${GCP_PROJECT_ID}`
    [Documentation]    Analyzes error patterns and response codes from Model Garden invocations to identify issues using Python SDK
    [Tags]    vertex-ai    error-analysis    response-codes    troubleshooting    access:read-only    data:logs-regexp
    # Analyze error patterns WITHOUT running discovery again
    ${error_analysis}=    RW.CLI.Run Cli
    ...    cmd=python3 vertex_ai_monitoring.py errors --hours 2 --no-discovery
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    show_in_rwl_cheatsheet=true
    ...    timeout_seconds=120
    
    # Consolidate all pre-report content into a single call
    ${consolidated_report}=    Catenate    SEPARATOR=\n
    ...    📊 ERROR ANALYSIS
    ...    ═══════════════════════════════════════════════════
    ...    📊 Found: ${DISCOVERED_MODELS} models, ${DISCOVERED_ENDPOINTS} endpoints
    ...    ${error_analysis.stdout}
    ...    ${EMPTY}
    ...    Commands Used: ${error_analysis.cmd}
    
    RW.Core.Add Pre To Report    ${consolidated_report}
    
    # Parse results and create issues if needed
    ${high_error_rate}=    Run Keyword And Return Status    Should Contain    ${error_analysis.stdout}    HIGH_ERROR_RATE:true
    ${error_count}=    Set Variable    0
    
    @{output_lines}=    Split String    ${error_analysis.stdout}    \n
    FOR    ${line}    IN    @{output_lines}
        ${line}=    Strip String    ${line}
        IF    'ERROR_COUNT:' in $line
            ${count_part}=    Split String    ${line}    :
            ${error_count}=    Strip String    ${count_part}[1]
            ${error_count}=    Convert To Number    ${error_count}
            BREAK
        END
    END
    
    IF    ${high_error_rate}
        RW.Core.Add Issue    
        ...    title=High error rate in Model Garden    
        ...    severity=1    
        ...    expected=Error rate <5%    
        ...    actual=Error rate >5%    
        ...    reproduce_hint=Review response codes and check for quota limits, authentication issues, or model availability
        ...    next_steps=Review Vertex AI Model Garden error logs and check for quota limits, authentication issues, or model availability
    END
    
    IF    ${error_count} > 0
        RW.Core.Add Issue    
        ...    title=Model Garden errors detected    
        ...    severity=2    
        ...    expected=Zero errors    
        ...    actual=${error_count} errors detected    
        ...    reproduce_hint=Check model configuration and quota limits for affected models
        ...    next_steps=Check model configuration and quota limits for affected models
    END

Investigate Vertex AI Model Latency Performance Issues in `${GCP_PROJECT_ID}`
    [Documentation]    Analyzes latency metrics to identify performance bottlenecks and degradation using Python SDK
    [Tags]    vertex-ai    latency    performance    analysis    access:read-only    data:config
    # Analyze latency performance WITHOUT running discovery again
    ${latency_analysis}=    RW.CLI.Run Cli
    ...    cmd=python3 vertex_ai_monitoring.py latency --hours 2 --no-discovery
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    show_in_rwl_cheatsheet=true
    ...    timeout_seconds=120
    
    # Consolidate all pre-report content into a single call
    ${consolidated_report}=    Catenate    SEPARATOR=\n
    ...    🚀 LATENCY ANALYSIS
    ...    ═══════════════════════════════════════════════════════
    ...    📊 Found: ${DISCOVERED_MODELS} models, ${DISCOVERED_ENDPOINTS} endpoints
    ...    ${latency_analysis.stdout}
    ...    ${EMPTY}
    ...    Commands Used: ${latency_analysis.cmd}
    
    RW.Core.Add Pre To Report    ${consolidated_report}
    
    # Parse results and create issues if needed
    ${high_latency_count}=    Set Variable    0
    ${elevated_latency_count}=    Set Variable    0
    
    @{output_lines}=    Split String    ${latency_analysis.stdout}    \n
    FOR    ${line}    IN    @{output_lines}
        ${line}=    Strip String    ${line}
        IF    'HIGH_LATENCY_MODELS:' in $line
            ${count_part}=    Split String    ${line}    :
            ${high_latency_count}=    Strip String    ${count_part}[1]
            ${high_latency_count}=    Convert To Number    ${high_latency_count}
        ELSE IF    'ELEVATED_LATENCY_MODELS:' in $line  
            ${count_part}=    Split String    ${line}    :
            ${elevated_latency_count}=    Strip String    ${count_part}[1]
            ${elevated_latency_count}=    Convert To Number    ${elevated_latency_count}
        END
    END
    
    IF    ${high_latency_count} > 0
        RW.Core.Add Issue    
        ...    title=High latency models detected    
        ...    severity=1    
        ...    expected=Latency <30s    
        ...    actual=${high_latency_count} models with >30s latency    
        ...    reproduce_hint=Check model load, increase provisioned throughput, or optimize requests
        ...    next_steps=Check model load, increase provisioned throughput, or optimize requests
    END
    
    IF    ${elevated_latency_count} > 0
        RW.Core.Add Issue    
        ...    title=Elevated latency models detected    
        ...    severity=2    
        ...    expected=Latency <10s    
        ...    actual=${elevated_latency_count} models with 10-30s latency    
        ...    reproduce_hint=Monitor model performance and consider optimization
        ...    next_steps=Monitor model performance and consider optimization
    END

Monitor Vertex AI Throughput and Token Consumption Patterns in `${GCP_PROJECT_ID}`
    [Documentation]    Analyzes throughput consumption and token usage patterns for capacity planning using Python SDK
    [Tags]    vertex-ai    throughput    tokens    capacity-planning    access:read-only    data:config

    # Analyze throughput and token consumption WITHOUT running discovery again
    ${throughput_analysis}=    RW.CLI.Run Cli
    ...    cmd=python3 vertex_ai_monitoring.py throughput --hours 2 --no-discovery
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    show_in_rwl_cheatsheet=true
    ...    timeout_seconds=120
    
    # Consolidate throughput report into a single call
    ${consolidated_report}=    Catenate    SEPARATOR=\n
    ...    📈 THROUGHPUT & TOKEN ANALYSIS
    ...    ══════════════════════════════════════════════════════════
    ...    📊 Found: ${DISCOVERED_MODELS} models, ${DISCOVERED_ENDPOINTS} endpoints
    ...    ${throughput_analysis.stdout}
    ...    ${EMPTY}
    ...    Commands Used: ${throughput_analysis.cmd}
    
    RW.Core.Add pre to Report    ${consolidated_report}

Check Vertex AI Model Garden API Logs for Issues in `${GCP_PROJECT_ID}`
    [Documentation]    Analyzes recent API logs for error patterns and usage issues
    [Tags]    vertex-ai    logs    api-calls    monitoring    access:read-only    data:logs-regexp
    
    # Use the exact working query from console - Vertex AI errors
    ${vertex_errors}=    RW.CLI.Run Cli
    ...    cmd=gcloud logging read 'resource.type="audited_resource" AND resource.labels.service="aiplatform.googleapis.com" AND severity="ERROR"' --format="json" --freshness="${LOG_FRESHNESS}" --limit=50 --project=${GCP_PROJECT_ID}
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    show_in_rwl_cheatsheet=true
    ...    timeout_seconds=120
    
    # Check if we got empty results and for permission errors
    ${has_vertex_errors}=    Run Keyword And Return Status    Should Not Be Empty    ${vertex_errors.stdout}
    ${empty_result}=    Run Keyword And Return Status    Should Be Equal    ${vertex_errors.stdout}    []\n
    
    # Check for actual permission errors in stderr or error messages
    ${has_permission_error}=    Run Keyword And Return Status    Should Contain Any    ${vertex_errors.stderr}    permission    denied    PERMISSION_DENIED    not authorized
    
    IF    ${has_permission_error}
        RW.Core.Add Issue    
        ...    title=Unable to access audit logs - missing permissions    
        ...    severity=2    
        ...    expected=Service account should have audit log access    
        ...    actual=Permission denied error when accessing audit logs    
        ...    reproduce_hint=Grant roles/logging.privateLogViewer to the service account to access audit logs
        ...    next_steps=Grant roles/logging.privateLogViewer role to the service account used by this robot
        
        ${consolidated_report}=    Catenate    SEPARATOR=\n
        ...    🔍 CHECKING VERTEX AI MODEL GARDEN API LOGS
        ...    ═══════════════════════════════════════════════
        ...    ❌ Permission denied accessing audit logs - service account needs roles/logging.privateLogViewer permission
        ...    ${EMPTY}
        ...    Commands Used: ${vertex_errors.cmd}
        
        RW.Core.Add Pre to Report    ${consolidated_report}
    ELSE IF    ${empty_result}
        # If we got empty results, it means no errors were found (not a permissions issue)
        ${consolidated_report}=    Catenate    SEPARATOR=\n
        ...    🔍 CHECKING VERTEX AI MODEL GARDEN API LOGS
        ...    ═══════════════════════════════════════════════
        ...    ✅ No Vertex AI errors found in logs for the last ${LOG_FRESHNESS} - system appears healthy
        ...    ${EMPTY}
        ...    Commands Used: ${vertex_errors.cmd}
        
        RW.Core.Add Pre to Report    ${consolidated_report}
    ELSE
        # We have actual log data to process
        # Count total errors - use Robot Framework file writing to avoid "Argument list too long"
        ${main_analysis_file}=    Set Variable    ./vertex_errors_analysis.json
        
        # Write JSON to file using Robot Framework instead of echo to avoid argument length limits
        Create File    ${main_analysis_file}    ${vertex_errors.stdout}
        
        ${vertex_error_count_result}=    RW.CLI.Run Cli
        ...    cmd=jq '. | length' ${main_analysis_file}
        ...    env=${env}
        
        # Handle empty results safely
        ${vertex_error_count_str}=    Strip String    ${vertex_error_count_result.stdout}
        ${vertex_error_count}=    Run Keyword If    '${vertex_error_count_str}' != ''    Convert To Number    ${vertex_error_count_str}    ELSE    Set Variable    0
        
        # Check for specific error types using the temp file - with safe conversion
        ${auth_errors_result}=    RW.CLI.Run Cli
        ...    cmd=jq '[.[] | select(.protoPayload.status.code == 7 or .protoPayload.status.code == 16)] | length' ${main_analysis_file}
        ...    env=${env}
        ${auth_error_count_str}=    Strip String    ${auth_errors_result.stdout}
        ${auth_error_count}=    Run Keyword If    '${auth_error_count_str}' != ''    Convert To Number    ${auth_error_count_str}    ELSE    Set Variable    0
        
        ${quota_errors_result}=    RW.CLI.Run Cli
        ...    cmd=jq '[.[] | select(.protoPayload.status.code == 8)] | length' ${main_analysis_file}
        ...    env=${env}
        ${quota_error_count_str}=    Strip String    ${quota_errors_result.stdout}
        ${quota_error_count}=    Run Keyword If    '${quota_error_count_str}' != ''    Convert To Number    ${quota_error_count_str}    ELSE    Set Variable    0
        
        # Check for service unavailable errors (code 14)
        ${service_errors_result}=    RW.CLI.Run Cli
        ...    cmd=jq '[.[] | select(.protoPayload.status.code == 14)] | length' ${main_analysis_file}
        ...    env=${env}
        ${service_unavailable_count_str}=    Strip String    ${service_errors_result.stdout}
        ${service_unavailable_count}=    Run Keyword If    '${service_unavailable_count_str}' != ''    Convert To Number    ${service_unavailable_count_str}    ELSE    Set Variable    0
        
        # Count ChatCompletions vs Predict calls
        ${chat_error_count_result}=    RW.CLI.Run Cli
        ...    cmd=jq '[.[] | select(.protoPayload.methodName == "google.cloud.aiplatform.v1.PredictionService.ChatCompletions")] | length' ${main_analysis_file}
        ...    env=${env}
        ${chat_error_count_str}=    Strip String    ${chat_error_count_result.stdout}
        ${chat_error_count}=    Run Keyword If    '${chat_error_count_str}' != ''    Convert To Number    ${chat_error_count_str}    ELSE    Set Variable    0
        
        ${predict_error_count_result}=    RW.CLI.Run Cli
        ...    cmd=jq '[.[] | select(.protoPayload.methodName == "google.cloud.aiplatform.v1.PredictionService.Predict")] | length' ${main_analysis_file}
        ...    env=${env}
        ${predict_error_count_str}=    Strip String    ${predict_error_count_result.stdout}
        ${predict_error_count}=    Run Keyword If    '${predict_error_count_str}' != ''    Convert To Number    ${predict_error_count_str}    ELSE    Set Variable    0
        
        # Build comprehensive error analysis report
        ${error_summary}=    Catenate    SEPARATOR=\n
        ...    🔍 VERTEX AI ERROR LOG ANALYSIS (Last ${LOG_FRESHNESS})
        ...    ═══════════════════════════════════════════════════════════
        ...    📋 ERROR SUMMARY:
        ...    • Total Vertex AI Errors: ${vertex_error_count}
        ...    • ChatCompletions errors: ${chat_error_count}
        ...    • Predict API errors: ${predict_error_count}
        ...    • Authentication errors (code 7,16): ${auth_error_count}
        ...    • Quota exceeded errors (code 8): ${quota_error_count}
        ...    • Service unavailable errors (code 14): ${service_unavailable_count}
        
        # Include detailed log entries if we found errors
        IF    ${vertex_error_count} > 0
            # Format the logs with timestamps, endpoints, and key details - use Robot Framework file writing
            ${temp_file}=    Set Variable    ./vertex_errors_${vertex_error_count}.json
            Create File    ${temp_file}    ${vertex_errors.stdout}
            
            ${formatted_logs}=    RW.CLI.Run Cli
            ...    cmd=jq -r '.[] | "🕐 " + .timestamp + " | " + .protoPayload.methodName + " | Endpoint: " + (.protoPayload.resourceName // "unknown") + " | Code: " + (.protoPayload.status.code | tostring) + " | " + .protoPayload.status.message + " | Caller: " + (.protoPayload.authenticationInfo.principalEmail // "unknown")' ${temp_file} 2>/dev/null || echo "Error formatting logs"
            ...    env=${env}
            
            # Build simplified error breakdown using temp file
            ${error_breakdown}=    RW.CLI.Run Cli
            ...    cmd=jq -r 'group_by(.protoPayload.status.code) | .[] | "Code " + (.[0].protoPayload.status.code | tostring) + ": " + (length | tostring) + " occurrences (" + .[0].protoPayload.status.message + ")"' ${temp_file} 2>/dev/null || echo "Error analyzing breakdown"
            ...    env=${env}
            
            # Clean up temp file
            ${cleanup}=    RW.CLI.Run Cli
            ...    cmd=rm -f ${temp_file}
            ...    env=${env}
            
            ${detailed_logs}=    Set Variable    ${formatted_logs.stdout}
            ${error_breakdown_text}=    Set Variable    ${error_breakdown.stdout}
        ELSE
            ${detailed_logs}=    Set Variable    No errors found
            ${error_breakdown_text}=    Set Variable    No errors to analyze
        END
        
        # Consolidate the complete error analysis into one report
        ${consolidated_report}=    Catenate    SEPARATOR=\n
        ...    ${error_summary}
        ...    ${EMPTY}
        ...    📝 DETAILED ERROR LOGS:
        ...    ${detailed_logs}
        ...    ${EMPTY}
        ...    📊 ERROR BREAKDOWN BY TYPE:
        ...    ${error_breakdown_text}
        ...    ${EMPTY}
        ...    Commands Used: ${vertex_errors.cmd}
        
        RW.Core.Add Pre to Report    ${consolidated_report}
        
        # Create issues for problems found with log snippets
        IF    ${vertex_error_count} > 10
            # Get recent log snippets for the issue - use Robot Framework file writing
            ${recent_temp_file}=    Set Variable    ./vertex_recent_errors.json
            Create File    ${recent_temp_file}    ${vertex_errors.stdout}
            
            ${recent_logs}=    RW.CLI.Run Cli
            ...    cmd=jq -r '.[:5] | .[] | "- " + .timestamp + " | " + .protoPayload.methodName + " | " + (.protoPayload.resourceName // "unknown") + " | Code " + (.protoPayload.status.code | tostring) + ": " + .protoPayload.status.message' ${recent_temp_file} 2>/dev/null || echo "Error getting log snippets"
            ...    env=${env}
            
            # Clean up temp file
            ${cleanup_recent}=    RW.CLI.Run Cli
            ...    cmd=rm -f ${recent_temp_file}
            ...    env=${env}
            
            RW.Core.Add Issue    
            ...    title=High number of Vertex AI errors detected in audit logs    
            ...    severity=2    
            ...    expected=Few or no API errors    
            ...    actual=${vertex_error_count} errors in the last ${LOG_FRESHNESS}    
            ...    reproduce_hint=Use query: resource.type="audited_resource" AND resource.labels.service="aiplatform.googleapis.com" AND severity="ERROR"    
            ...    details=Recent error examples:\n${recent_logs.stdout}    
            ...    next_steps=Review error logs for patterns and root causes. Check the Vertex AI audit resource logs for detailed error information.
        ELSE IF    ${vertex_error_count} > 0
            # Get all log snippets for smaller number of errors - use Robot Framework file writing
            ${small_errors_temp_file}=    Set Variable    ./vertex_small_errors.json
            Create File    ${small_errors_temp_file}    ${vertex_errors.stdout}
            
            ${all_logs}=    RW.CLI.Run Cli
            ...    cmd=jq -r '.[] | "- " + .timestamp + " | " + .protoPayload.methodName + " | " + (.protoPayload.resourceName // "unknown") + " | Code " + (.protoPayload.status.code | tostring) + ": " + .protoPayload.status.message' ${small_errors_temp_file} 2>/dev/null || echo "Error getting all logs"
            ...    env=${env}
            
            # Clean up temp file
            ${cleanup_small}=    RW.CLI.Run Cli
            ...    cmd=rm -f ${small_errors_temp_file}
            ...    env=${env}
            
            RW.Core.Add Issue    
            ...    title=Vertex AI errors detected in audit logs    
            ...    severity=2    
            ...    expected=No API errors    
            ...    actual=${vertex_error_count} errors in the last ${LOG_FRESHNESS}    
            ...    details=Error details:\n${all_logs.stdout}    
            ...    reproduce_hint=Use query: resource.type="audited_resource" AND resource.labels.service="aiplatform.googleapis.com" AND severity="ERROR"
            ...    next_steps=Review error logs to identify specific issues. Check Vertex AI audit resource logs for detailed error information.
        END
        
        IF    ${auth_error_count} > 0
            # Get auth error snippets - use Robot Framework file writing
            ${auth_temp_file}=    Set Variable    ./vertex_auth_errors.json
            Create File    ${auth_temp_file}    ${vertex_errors.stdout}
            
            ${auth_log_snippets}=    RW.CLI.Run Cli
            ...    cmd=jq -r '.[] | select(.protoPayload.status.code == 7 or .protoPayload.status.code == 16) | "- " + .timestamp + " | " + .protoPayload.methodName + " | " + (.protoPayload.resourceName // "unknown") + " | " + (.protoPayload.authenticationInfo.principalEmail // "unknown") + " | " + .protoPayload.status.message' ${auth_temp_file} 2>/dev/null || echo "Error getting auth logs"
            ...    env=${env}
            
            # Clean up temp file
            ${cleanup_auth}=    RW.CLI.Run Cli
            ...    cmd=rm -f ${auth_temp_file}
            ...    env=${env}
            
            RW.Core.Add Issue    
            ...    title=Authentication errors detected in Vertex AI logs    
            ...    severity=2    
            ...    expected=No authentication errors    
            ...    actual=${auth_error_count} authentication errors found in logs    
            ...    details=Authentication error details:\n${auth_log_snippets.stdout}    
            ...    reproduce_hint=Use query: resource.type="audited_resource" AND resource.labels.service="aiplatform.googleapis.com" AND severity="ERROR"
            ...    next_steps=Check service account permissions and API key configuration
        END
        
        IF    ${quota_error_count} > 0
            RW.Core.Add Issue    
            ...    title=Quota errors detected in Vertex AI logs    
            ...    severity=2    
            ...    expected=No quota exceeded errors    
            ...    actual=${quota_error_count} quota errors found in logs    
            ...    reproduce_hint=Use query: resource.type="audited_resource" AND resource.labels.service="aiplatform.googleapis.com" AND severity="ERROR"
            ...    next_steps=Check quota limits and increase if necessary
        END
    END

    # Clean up temporary files
    ${cleanup_files}=    RW.CLI.Run Cli
    ...    cmd=rm -f ./vertex_errors_*.json ./vertex_recent_errors.json ./vertex_small_errors.json ./vertex_auth_errors.json
    ...    env=${env}

Check Vertex AI Model Garden Service Health and Quotas in `${GCP_PROJECT_ID}`
    [Documentation]    Performs comprehensive health checks on Vertex AI services and quotas
    [Tags]    vertex-ai    health-check    quotas    service-status    access:read-only    data:config
    
    # Check overall service health WITHOUT running discovery again
    ${health_check}=    RW.CLI.Run Cli
    ...    cmd=python3 vertex_ai_monitoring.py health
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    show_in_rwl_cheatsheet=true
    ...    timeout_seconds=120
    
    ${consolidated_report}=    Catenate    SEPARATOR=\n
    ...    🏥 SERVICE HEALTH CHECK
    ...    ═══════════════════════════════════════════════════════
    ...    📊 Found: ${DISCOVERED_MODELS} models, ${DISCOVERED_ENDPOINTS} endpoints
    ...    ${health_check.stdout}
    ...    ${EMPTY}
    ...    Commands Used: ${health_check.cmd}
    
    RW.Core.Add Pre to Report    ${consolidated_report}

Generate Vertex AI Model Garden Health Summary and Next Steps for `${GCP_PROJECT_ID}`
    [Documentation]    Generates a comprehensive health summary with actionable recommendations
    [Tags]    summary    health-report    recommendations    access:read-only
    
    ${current_date}=    Get Current Date    result_format=%Y-%m-%d %H:%M:%S UTC
    
    ${summary_report}=    Catenate    SEPARATOR=\n
    ...    📊 VERTEX AI MODEL GARDEN HEALTH SUMMARY
    ...    ══════════════════════════════════════════════
    ...    Project: ${GCP_PROJECT_ID}
    ...    Analysis Period: Last 2 hours
    ...    Timestamp: ${current_date}
    ...    ${EMPTY}
    ...    📚 USEFUL DOCUMENTATION:
    ...    - Model Garden Monitoring: https://cloud.google.com/vertex-ai/docs/model-garden/monitor-models
    ...    - Provisioned Throughput: https://cloud.google.com/vertex-ai/generative-ai/docs/provisioned-throughput
    ...    - Error Troubleshooting: https://cloud.google.com/vertex-ai/docs/general/troubleshooting
    ...    - Quota Management: https://cloud.google.com/vertex-ai/quotas
    
    RW.Core.Add Pre To Report    ${summary_report}

Generate Normalized Health Report Table for `${GCP_PROJECT_ID}`
    [Documentation]    Generates a normalized tabular health report for regular monitoring of all LLAMA models (MaaS and Self-hosted)
    [Tags]    vertex-ai    health-report    monitoring    table    access:read-only    data:config
    
    # Generate comprehensive health report table
    ${health_report_table}=    RW.CLI.Run Cli
    ...    cmd=python3 vertex_ai_monitoring.py report --hours 2 ${region_args}
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    show_in_rwl_cheatsheet=true
    ...    timeout_seconds=180
    
    # Parse key metrics from the report
    ${total_models}=    Set Variable    0
    ${healthy_models}=    Set Variable    0
    ${warning_models}=    Set Variable    0
    ${critical_models}=    Set Variable    0
    ${inactive_models}=    Set Variable    0
    ${total_token_rate}=    Set Variable    0.0
    
    @{report_lines}=    Split String    ${health_report_table.stdout}    \n
    FOR    ${line}    IN    @{report_lines}
        ${line}=    Strip String    ${line}
        IF    'TOTAL_MODELS:' in $line
            ${count_part}=    Split String    ${line}    :
            ${total_models}=    Strip String    ${count_part}[1]
            ${total_models}=    Convert To Number    ${total_models}
        ELSE IF    'HEALTHY_MODELS:' in $line
            ${count_part}=    Split String    ${line}    :
            ${healthy_models}=    Strip String    ${count_part}[1]
            ${healthy_models}=    Convert To Number    ${healthy_models}
        ELSE IF    'WARNING_MODELS:' in $line
            ${count_part}=    Split String    ${line}    :
            ${warning_models}=    Strip String    ${count_part}[1]
            ${warning_models}=    Convert To Number    ${warning_models}
        ELSE IF    'CRITICAL_MODELS:' in $line
            ${count_part}=    Split String    ${line}    :
            ${critical_models}=    Strip String    ${count_part}[1]
            ${critical_models}=    Convert To Number    ${critical_models}
        ELSE IF    'INACTIVE_MODELS:' in $line
            ${count_part}=    Split String    ${line}    :
            ${inactive_models}=    Strip String    ${count_part}[1]
            ${inactive_models}=    Convert To Number    ${inactive_models}
        ELSE IF    'TOTAL_TOKEN_RATE:' in $line
            ${count_part}=    Split String    ${line}    :
            ${total_token_rate}=    Strip String    ${count_part}[1]
            ${total_token_rate}=    Convert To Number    ${total_token_rate}
        END
    END
    
    # Create consolidated report showing the health table
    ${consolidated_report}=    Catenate    SEPARATOR=\n
    ...    📊 NORMALIZED VERTEX AI MODEL HEALTH REPORT
    ...    ══════════════════════════════════════════════════════════
    ...    ${health_report_table.stdout}
    ...    ${EMPTY}
    ...    📋 EXECUTIVE SUMMARY:
    ...    • Total Models Monitored: ${total_models}
    ...    • Health Status: ${healthy_models} Healthy, ${warning_models} Warning, ${critical_models} Critical, ${inactive_models} Inactive
    ...    • Token Consumption: ${total_token_rate} tokens/sec
    ...    ${EMPTY}
    ...    Command Used: ${health_report_table.cmd}
    
    RW.Core.Add Pre to Report    ${consolidated_report}
    
    # Create issues based on health status
    IF    ${critical_models} > 0
        RW.Core.Add Issue    
        ...    title=Critical model health issues detected    
        ...    severity=1    
        ...    expected=All models should be healthy or have acceptable performance    
        ...    actual=${critical_models} models in critical state    
        ...    reproduce_hint=Run: python3 vertex_ai_monitoring.py report --hours 2    
        ...    next_steps=Review the models marked as Critical in the health report table and investigate high error rates or performance issues
    END
    
    IF    ${warning_models} > 0
        RW.Core.Add Issue    
        ...    title=Model performance warnings detected    
        ...    severity=3    
        ...    expected=All models should have optimal performance    
        ...    actual=${warning_models} models with performance warnings    
        ...    reproduce_hint=Run: python3 vertex_ai_monitoring.py report --hours 2    
        ...    next_steps=Review the models marked as Warning in the health report table for elevated error rates or latency issues
    END
    
    IF    ${total_models} == 0
        RW.Core.Add Issue    
        ...    title=No models found for health monitoring    
        ...    severity=2    
        ...    expected=At least one model should be available for monitoring    
        ...    actual=No models detected with monitoring data    
        ...    reproduce_hint=Run: python3 vertex_ai_monitoring.py discover and python3 vertex_ai_monitoring.py report    
        ...    next_steps=Verify that models are deployed and generating traffic, or check monitoring permissions
    END

*** Keywords ***
Suite Initialization
    ${gcp_credentials}=    RW.Core.Import Secret    gcp_credentials
    ...    type=string
    ...    description=GCP service account json used to authenticate with GCP APIs.
    ...    pattern=\w*
    ...    example={"type": "service_account","project_id":"myproject-ID", ... super secret stuff ...}
    
    # Try multiple ways to get GCP_PROJECT_ID to handle Robot Framework quirks
    TRY
        ${GCP_PROJECT_ID}=    RW.Core.Import User Variable    GCP_PROJECT_ID
        ...    type=string
        ...    description=The GCP Project ID to scope the API to.
        ...    pattern=\w*
        ...    example=myproject-ID
    EXCEPT
        # Fallback: try to get from environment
        ${GCP_PROJECT_ID}=    Get Environment Variable    GCP_PROJECT_ID    ${EMPTY}
    END
    
    # Ensure GCP_PROJECT_ID is not empty
    ${project_length}=    Get Length    ${GCP_PROJECT_ID}
    ${project_stripped}=    Strip String    ${GCP_PROJECT_ID}
    IF    ${project_length} == 0 or '${project_stripped}' == ''
        Fail    GCP_PROJECT_ID is required but was not provided. Set it as a user variable or environment variable.
    END
    ${LOG_FRESHNESS}=    RW.Core.Import User Variable    LOG_FRESHNESS
    ...    type=string
    ...    description=Time window for log analysis (e.g., 1h, 30m, 2h, 1d).
    ...    pattern=\w*
    ...    example=2h
    ...    default=2h
    ${VERTEX_AI_REGIONS}=    RW.Core.Import User Variable    VERTEX_AI_REGIONS
    ...    type=string
    ...    description=Comma-separated list of regions to check for model discovery (optional). Use 'fast' for common US regions, 'us-only' for all US regions, 'priority' for worldwide common regions.
    ...    pattern=\w*
    ...    example=us-central1,us-east4,us-east5
    ...    default=
    ${OS_PATH}=    Get Environment Variable    PATH
    Set Suite Variable    ${GCP_PROJECT_ID}    ${GCP_PROJECT_ID}
    Set Suite Variable    ${LOG_FRESHNESS}    ${LOG_FRESHNESS}
    Set Suite Variable    ${VERTEX_AI_REGIONS}    ${VERTEX_AI_REGIONS}
    Set Suite Variable    ${gcp_credentials}    ${gcp_credentials}
    
    # Build environment with region settings
    ${region_args}=    Set Variable    ${EMPTY}
    IF    '${VERTEX_AI_REGIONS}' == 'fast'
        ${region_args}=    Set Variable    --fast
    ELSE IF    '${VERTEX_AI_REGIONS}' == 'us-only'
        ${region_args}=    Set Variable    --us-only
    ELSE IF    '${VERTEX_AI_REGIONS}' == 'priority'
        ${region_args}=    Set Variable    --priority-regions
    ELSE IF    '${VERTEX_AI_REGIONS}' != ''
        ${region_args}=    Set Variable    --regions ${VERTEX_AI_REGIONS}
    END
    Set Suite Variable    ${region_args}    ${region_args}
    
    Set Suite Variable
    ...    ${env}
    ...    {"CLOUDSDK_CORE_PROJECT":"${GCP_PROJECT_ID}","GOOGLE_APPLICATION_CREDENTIALS":"./${gcp_credentials.key}","PATH":"$PATH:${OS_PATH}","VERTEX_AI_REGIONS":"${VERTEX_AI_REGIONS}"}
    
    # Activate service account once for all gcloud commands
    RW.CLI.Run Cli
    ...    cmd=gcloud auth activate-service-account --key-file=$GOOGLE_APPLICATION_CREDENTIALS
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials} 