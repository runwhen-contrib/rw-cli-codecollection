*** Settings ***
Documentation       Troubleshooting and remediation tasks for GCP Vertex AI Model Garden using Google Cloud Monitoring Python SDK.
...                 
...                 Required IAM Roles:
...                 - roles/monitoring.viewer (for metrics access)
...                 - roles/logging.privateLogViewer (for audit logs access)
...                 - roles/serviceusage.serviceUsageConsumer (for service status checks)
...                 
...                 Required Permissions:
...                 - monitoring.timeSeries.list
...                 - logging.privateLogEntries.list
...                 - serviceusage.services.list
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
Analyze Vertex AI Model Garden Error Patterns and Response Codes in `${GCP_PROJECT_ID}`
    [Documentation]    Analyzes error patterns and response codes from Model Garden invocations to identify issues using Python SDK
    [Tags]    vertex-ai    error-analysis    response-codes    troubleshooting    access:read-only
    # Analyze error patterns using Python script
    ${error_analysis}=    RW.CLI.Run Cli
    ...    cmd=python3 vertex_ai_monitoring.py errors --hours 2
    ...    env=${env}
    ...    secret_file__gcp_credentials_json=${gcp_credentials_json}
    ...    show_in_rwl_cheatsheet=true
    ...    timeout_seconds=240
    
    # Consolidate all pre-report content into a single call
    ${consolidated_report}=    Catenate    SEPARATOR=\n
    ...    📊 ANALYZING VERTEX AI MODEL GARDEN ERROR PATTERNS
    ...    ═══════════════════════════════════════════════════
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
        IF    'ERROR_COUNT:' in '${line}'
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
    [Tags]    vertex-ai    latency    performance    analysis    access:read-only
    # Analyze latency performance using Python script
    ${latency_analysis}=    RW.CLI.Run Cli
    ...    cmd=python3 vertex_ai_monitoring.py latency --hours 2
    ...    env=${env}
    ...    secret_file__gcp_credentials_json=${gcp_credentials_json}
    ...    show_in_rwl_cheatsheet=true
    ...    timeout_seconds=240
    
    # Consolidate all pre-report content into a single call
    ${consolidated_report}=    Catenate    SEPARATOR=\n
    ...    🚀 INVESTIGATING VERTEX AI MODEL LATENCY PERFORMANCE
    ...    ═══════════════════════════════════════════════════════
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
        IF    'HIGH_LATENCY_MODELS:' in '${line}'
            ${count_part}=    Split String    ${line}    :
            ${high_latency_count}=    Strip String    ${count_part}[1]
            ${high_latency_count}=    Convert To Number    ${high_latency_count}
        ELSE IF    'ELEVATED_LATENCY_MODELS:' in '${line}'  
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
    [Tags]    vertex-ai    throughput    tokens    capacity-planning    access:read-only

    # Analyze throughput and token consumption using Python script
    ${throughput_analysis}=    RW.CLI.Run Cli
    ...    cmd=python3 vertex_ai_monitoring.py throughput --hours 2
    ...    env=${env}
    ...    secret_file__gcp_credentials_json=${gcp_credentials_json}
    ...    show_in_rwl_cheatsheet=true
    ...    timeout_seconds=240
    
    # Consolidate throughput report into a single call
    ${consolidated_report}=    Catenate    SEPARATOR=\n
    ...    📈 MONITORING VERTEX AI THROUGHPUT AND TOKEN CONSUMPTION
    ...    ══════════════════════════════════════════════════════════
    ...    ${throughput_analysis.stdout}
    ...    ${EMPTY}
    ...    Commands Used: ${throughput_analysis.cmd}
    
    RW.Core.Add Pre to Report    ${consolidated_report}

Check Vertex AI Model Garden API Logs for Issues in `${GCP_PROJECT_ID}`
    [Documentation]    Analyzes recent API logs for error patterns and usage issues
    [Tags]    vertex-ai    logs    api-calls    monitoring    access:read-only
    
    # Use the exact working query from console - Vertex AI errors
    ${vertex_errors}=    RW.CLI.Run Cli
    ...    cmd=gcloud logging read 'resource.type="audited_resource" AND resource.labels.service="aiplatform.googleapis.com" AND severity="ERROR"' --format="json" --freshness="${LOG_FRESHNESS}" --limit=50 --project=${GCP_PROJECT_ID}
    ...    env=${env}
    ...    secret_file__gcp_credentials_json=${gcp_credentials_json}
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
        # Parse the vertex errors we found
        ${vertex_error_count}=    Set Variable    0
        ${auth_error_count}=    Set Variable    0
        ${quota_error_count}=    Set Variable    0
        ${service_unavailable_count}=    Set Variable    0
        
        # Count total errors
        ${vertex_count_result}=    RW.CLI.Run Cli
        ...    cmd=echo '${vertex_errors.stdout}' > vertex_errors_runbook.json && jq '. | length' vertex_errors_runbook.json && rm -f vertex_errors_runbook.json
        ...    env=${env}
        ${vertex_error_count}=    Convert To Number    ${vertex_count_result.stdout}
        
        # Check for specific error types
        ${auth_errors}=    RW.CLI.Run Cli
        ...    cmd=echo '${vertex_errors.stdout}' > vertex_errors_runbook.json && jq '[.[] | select(.protoPayload.status.code == 7 or .protoPayload.status.code == 16)] | length' vertex_errors_runbook.json
        ...    env=${env}
        ${auth_error_count}=    Convert To Number    ${auth_errors.stdout}
        
        ${quota_errors}=    RW.CLI.Run Cli
        ...    cmd=jq '[.[] | select(.protoPayload.status.code == 8)] | length' vertex_errors_runbook.json
        ...    env=${env}
        ${quota_error_count}=    Convert To Number    ${quota_errors.stdout}
        
        # Check for service unavailable errors (code 14)
        ${service_errors}=    RW.CLI.Run Cli
        ...    cmd=jq '[.[] | select(.protoPayload.status.code == 14)] | length' vertex_errors_runbook.json
        ...    env=${env}
        ${service_unavailable_count}=    Convert To Number    ${service_errors.stdout}
        
        # Count ChatCompletions vs Predict calls
        ${chat_error_count}=    RW.CLI.Run Cli
        ...    cmd=jq '[.[] | select(.protoPayload.methodName == "google.cloud.aiplatform.v1.PredictionService.ChatCompletions")] | length' vertex_errors_runbook.json
        ...    env=${env}
        ${chat_error_count}=    Convert To Number    ${chat_error_count.stdout}
        
        ${predict_error_count}=    RW.CLI.Run Cli
        ...    cmd=jq '[.[] | select(.protoPayload.methodName == "google.cloud.aiplatform.v1.PredictionService.Predict")] | length' vertex_errors_runbook.json && rm -f vertex_errors_runbook.json
        ...    env=${env}
        ${predict_error_count}=    Convert To Number    ${predict_error_count.stdout}
        
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
            # Format the logs with timestamps, endpoints, and key details
            ${formatted_logs}=    RW.CLI.Run Cli
            ...    cmd=echo '${vertex_errors.stdout}' > vertex_errors_detail.json && jq -r '.[] | "🕐 " + .timestamp + " | " + .protoPayload.methodName + " | Endpoint: " + (.protoPayload.resourceName // "unknown") + " | Code: " + (.protoPayload.status.code | tostring) + " | " + .protoPayload.status.message + " | Caller: " + .protoPayload.authenticationInfo.principalEmail' vertex_errors_detail.json
            ...    env=${env}
            
            ${detailed_logs}=    Set Variable    ${EMPTY}
            @{log_lines}=    Split String    ${formatted_logs.stdout}    \n
            FOR    ${log_line}    IN    @{log_lines}
                ${log_line}=    Strip String    ${log_line}
                IF    '${log_line}' != ''
                    ${detailed_logs}=    Catenate    SEPARATOR=\n    ${detailed_logs}    ${log_line}
                END
            END
            
            # Build error breakdown by type
            ${error_breakdown}=    Set Variable    ${EMPTY}
            
            # Show service unavailable details if present
            IF    ${service_unavailable_count} > 0
                ${service_unavailable_details}=    RW.CLI.Run Cli
                ...    cmd=jq -r '.[] | select(.protoPayload.status.code == 14) | "• " + .timestamp + " - " + .protoPayload.methodName + " - " + .protoPayload.status.message' vertex_errors_detail.json
                ...    env=${env}
                
                ${service_lines}=    Set Variable    ${EMPTY}
                @{service_lines_array}=    Split String    ${service_unavailable_details.stdout}    \n
                FOR    ${service_line}    IN    @{service_lines_array}
                    ${service_line}=    Strip String    ${service_line}
                    IF    '${service_line}' != ''
                        ${service_lines}=    Catenate    SEPARATOR=\n    ${service_lines}    ${service_line}
                    END
                END
                
                ${error_breakdown}=    Catenate    SEPARATOR=\n
                ...    ${error_breakdown}
                ...    ${EMPTY}
                ...    Service Unavailable Errors (${service_unavailable_count}):
                ...    ${service_lines}
            END
            
            # Show auth errors if present
            IF    ${auth_error_count} > 0
                ${auth_error_details}=    RW.CLI.Run Cli
                ...    cmd=jq -r '.[] | select(.protoPayload.status.code == 7 or .protoPayload.status.code == 16) | "• " + .timestamp + " - " + .protoPayload.methodName + " - " + .protoPayload.status.message' vertex_errors_detail.json
                ...    env=${env}
                
                ${auth_lines}=    Set Variable    ${EMPTY}
                @{auth_lines_array}=    Split String    ${auth_error_details.stdout}    \n
                FOR    ${auth_line}    IN    @{auth_lines_array}
                    ${auth_line}=    Strip String    ${auth_line}
                    IF    '${auth_line}' != ''
                        ${auth_lines}=    Catenate    SEPARATOR=\n    ${auth_lines}    ${auth_line}
                    END
                END
                
                ${error_breakdown}=    Catenate    SEPARATOR=\n
                ...    ${error_breakdown}
                ...    ${EMPTY}
                ...    Authentication Errors (${auth_error_count}):
                ...    ${auth_lines}
            END
            
            # Show quota errors if present
            IF    ${quota_error_count} > 0
                ${quota_error_details}=    RW.CLI.Run Cli
                ...    cmd=jq -r '.[] | select(.protoPayload.status.code == 8) | "• " + .timestamp + " - " + .protoPayload.methodName + " - " + .protoPayload.status.message' vertex_errors_detail.json
                ...    env=${env}
                
                ${quota_lines}=    Set Variable    ${EMPTY}
                @{quota_lines_array}=    Split String    ${quota_error_details.stdout}    \n
                FOR    ${quota_line}    IN    @{quota_lines_array}
                    ${quota_line}=    Strip String    ${quota_line}
                    IF    '${quota_line}' != ''
                        ${quota_lines}=    Catenate    SEPARATOR=\n    ${quota_lines}    ${quota_line}
                    END
                END
                
                ${error_breakdown}=    Catenate    SEPARATOR=\n
                ...    ${error_breakdown}
                ...    ${EMPTY}
                ...    Quota Exceeded Errors (${quota_error_count}):
                ...    ${quota_lines}
            END
            
            # Cleanup the temporary file
            RW.CLI.Run Cli
            ...    cmd=rm -f vertex_errors_detail.json
            ...    env=${env}
            
            # Consolidate the complete error analysis into one report
            ${consolidated_report}=    Catenate    SEPARATOR=\n
            ...    ${error_summary}
            ...    ${EMPTY}
            ...    📝 DETAILED ERROR LOGS:
            ...    ${detailed_logs}
            ...    ${EMPTY}
            ...    📊 ERROR BREAKDOWN BY TYPE:
            ...    ${error_breakdown}
            ...    ${EMPTY}
            ...    Commands Used: ${vertex_errors.cmd}
        ELSE
            ${consolidated_report}=    Catenate    SEPARATOR=\n
            ...    ${error_summary}
            ...    ${EMPTY}
            ...    Commands Used: ${vertex_errors.cmd}
        END
        
        RW.Core.Add Pre to Report    ${consolidated_report}
        
        # Create issues for problems found with log snippets
        IF    ${vertex_error_count} > 10
            # Get recent log snippets for the issue
            ${recent_logs}=    RW.CLI.Run Cli
            ...    cmd=echo '${vertex_errors.stdout}' > vertex_errors_issues.json && jq -r '.[:5] | .[] | "- " + .timestamp + " | " + .protoPayload.methodName + " | " + (.protoPayload.resourceName // "unknown") + " | Code " + (.protoPayload.status.code | tostring) + ": " + .protoPayload.status.message' vertex_errors_issues.json
            ...    env=${env}
            
            RW.Core.Add Issue    
            ...    title=High number of Vertex AI errors detected in audit logs    
            ...    severity=2    
            ...    expected=Few or no API errors    
            ...    actual=${vertex_error_count} errors in the last ${LOG_FRESHNESS}    
            ...    details=Recent error examples:\n${recent_logs.stdout}    
            ...    reproduce_hint=Use query: resource.type="audited_resource" AND resource.labels.service="aiplatform.googleapis.com" AND severity="ERROR"
            ...    next_steps=Review error logs for patterns and root causes. Check the Vertex AI audit resource logs for detailed error information.
        ELSE IF    ${vertex_error_count} > 0
            # Get all log snippets for smaller number of errors
            ${all_logs}=    RW.CLI.Run Cli
            ...    cmd=jq -r '.[] | "- " + .timestamp + " | " + .protoPayload.methodName + " | " + (.protoPayload.resourceName // "unknown") + " | Code " + (.protoPayload.status.code | tostring) + ": " + .protoPayload.status.message' vertex_errors_issues.json
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
            ${auth_log_snippets}=    RW.CLI.Run Cli
            ...    cmd=jq -r '.[] | select(.protoPayload.status.code == 7 or .protoPayload.status.code == 16) | "- " + .timestamp + " | " + .protoPayload.methodName + " | " + (.protoPayload.resourceName // "unknown") + " | " + .protoPayload.authenticationInfo.principalEmail + " | " + .protoPayload.status.message' vertex_errors_issues.json
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
            ${quota_log_snippets}=    RW.CLI.Run Cli
            ...    cmd=jq -r '.[] | select(.protoPayload.status.code == 8) | "- " + .timestamp + " | " + .protoPayload.methodName + " | " + (.protoPayload.resourceName // "unknown") + " | " + .protoPayload.authenticationInfo.principalEmail + " | " + .protoPayload.status.message' vertex_errors_issues.json
            ...    env=${env}
            
            RW.Core.Add Issue    
            ...    title=Quota exceeded errors detected in Vertex AI logs    
            ...    severity=2    
            ...    expected=No quota errors    
            ...    actual=${quota_error_count} quota exceeded errors found in logs    
            ...    details=Quota error details:\n${quota_log_snippets.stdout}    
            ...    reproduce_hint=Use query: resource.type="audited_resource" AND resource.labels.service="aiplatform.googleapis.com" AND severity="ERROR"
            ...    next_steps=Review quota limits and request increases if needed
        END
        
        IF    ${service_unavailable_count} > 0
            ${service_log_snippets}=    RW.CLI.Run Cli
            ...    cmd=jq -r '.[] | select(.protoPayload.status.code == 14) | "- " + .timestamp + " | " + .protoPayload.methodName + " | " + (.protoPayload.resourceName // "unknown") + " | " + .protoPayload.authenticationInfo.principalEmail + " | " + .protoPayload.status.message' vertex_errors_issues.json
            ...    env=${env}
            
            RW.Core.Add Issue    
            ...    title=Service unavailable errors detected in Vertex AI logs    
            ...    severity=2    
            ...    expected=Vertex AI service should be available    
            ...    actual=${service_unavailable_count} service unavailable errors found in logs    
            ...    details=Service unavailable error details:\n${service_log_snippets.stdout}    
            ...    reproduce_hint=Use query: resource.type="audited_resource" AND resource.labels.service="aiplatform.googleapis.com" AND severity="ERROR"
            ...    next_steps=Check Vertex AI service status and endpoint availability. The service may be experiencing outages.
        END
        
        # Cleanup issue processing temp file
        RW.CLI.Run Cli
        ...    cmd=rm -f vertex_errors_issues.json
        ...    env=${env}
    END

Check Vertex AI Model Garden Service Health and Quotas in `${GCP_PROJECT_ID}`
    [Documentation]    Verifies service availability and quota status for Model Garden using Python SDK
    [Tags]    vertex-ai    service-health    quotas    configuration    access:read-only
    
    # Check if Vertex AI services are enabled
    ${service_status}=    RW.CLI.Run Cli
    ...    cmd=gcloud services list --enabled --filter="name:aiplatform.googleapis.com" --format="table[no-heading](name)" --project=${GCP_PROJECT_ID}
    ...    env=${env}
    ...    secret_file__gcp_credentials_json=${gcp_credentials_json}
    
    # Check service health using Python script
    ${metrics_check}=    RW.CLI.Run Cli
    ...    cmd=python3 vertex_ai_monitoring.py health
    ...    env=${env}
    ...    secret_file__gcp_credentials_json=${gcp_credentials_json}
    ...    show_in_rwl_cheatsheet=true
    
    ${api_enabled}=    Run Keyword And Return Status    Should Contain    ${service_status.stdout}    aiplatform.googleapis.com
    
    # Build consolidated service health report
    ${service_status_text}=    Set Variable If    ${api_enabled}    ✅ Vertex AI API is enabled    ❌ Vertex AI API is not enabled
    ${consolidated_report}=    Catenate    SEPARATOR=\n
    ...    🏥 CHECKING VERTEX AI MODEL GARDEN SERVICE HEALTH
    ...    ═══════════════════════════════════════════════════════
    ...    ${service_status_text}
    ...    ${EMPTY}
    ...    📊 HEALTH METRICS:
    ...    ${metrics_check.stdout}
    ...    ${EMPTY}
    ...    Commands Used: ${metrics_check.cmd}
    
    RW.Core.Add  To Report    ${consolidated_report}
    
    IF    not ${api_enabled}
        RW.Core.Add Issue    
        ...    title=Vertex AI API not enabled    
        ...    severity=1    
        ...    expected=API should be enabled    
        ...    actual=API not found in enabled services    
        ...    reproduce_hint=Run: gcloud services enable aiplatform.googleapis.com --project=${GCP_PROJECT_ID}
        ...    next_steps=Run: gcloud services enable aiplatform.googleapis.com --project=${GCP_PROJECT_ID}
    END

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

*** Keywords ***
Suite Initialization
    ${gcp_credentials_json}=    RW.Core.Import Secret    gcp_credentials_json
    ...    type=string
    ...    description=GCP service account json used to authenticate with GCP APIs.
    ...    pattern=\w*
    ...    example={"type": "service_account","project_id":"myproject-ID", ... super secret stuff ...}
    ${GCP_PROJECT_ID}=    RW.Core.Import User Variable    GCP_PROJECT_ID
    ...    type=string
    ...    description=The GCP Project ID to scope the API to.
    ...    pattern=\w*
    ...    example=myproject-ID
    ${LOG_FRESHNESS}=    RW.Core.Import User Variable    LOG_FRESHNESS
    ...    type=string
    ...    description=Time window for log analysis (e.g., 1h, 30m, 2h, 1d).
    ...    pattern=\w*
    ...    example=2h
    ...    default=2h
    ${OS_PATH}=    Get Environment Variable    PATH
    Set Suite Variable    ${GCP_PROJECT_ID}    ${GCP_PROJECT_ID}
    Set Suite Variable    ${LOG_FRESHNESS}    ${LOG_FRESHNESS}
    Set Suite Variable    ${gcp_credentials_json}    ${gcp_credentials_json}
    Set Suite Variable
    ...    ${env}
    ...    {"CLOUDSDK_CORE_PROJECT":"${GCP_PROJECT_ID}","GOOGLE_APPLICATION_CREDENTIALS":"./${gcp_credentials_json.key}","PATH":"$PATH:${OS_PATH}"}
    
    # Activate service account once for all gcloud commands
    RW.CLI.Run Cli
    ...    cmd=gcloud auth activate-service-account --key-file=$GOOGLE_APPLICATION_CREDENTIALS
    ...    env=${env}
    ...    secret_file__gcp_credentials_json=${gcp_credentials_json} 