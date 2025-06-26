*** Settings ***
Documentation       Troubleshooting and remediation tasks for GCP Vertex AI Model Garden using Google Cloud Monitoring Python SDK.
Metadata            Author    runwhen
Metadata            Display Name    GCP Vertex AI Model Garden Troubleshooting
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
Analyze Vertex AI Model Garden Error Patterns and Response Codes
    [Documentation]    Analyzes error patterns and response codes from Model Garden invocations to identify issues using Python SDK
    [Tags]    vertex-ai    error-analysis    response-codes    troubleshooting
    RW.Core.Add Pre To Report    Analyzing Vertex AI Model Garden error patterns and response codes...
    
    # Analyze error patterns using Python script
    ${error_analysis}=    RW.CLI.Run Cli
    ...    cmd=python3 vertex_ai_monitoring.py errors --hours 2
    ...    env=${env}
    ...    secret_file__gcp_credentials_json=${gcp_credentials_json}
    ...    show_in_rwl_cheatsheet=true
    ...    timeout_seconds=240
    
    RW.Core.Add To Report    ${error_analysis.stdout}
    RW.Core.Add Pre To Report    Commands Used:\n${error_analysis.cmd}
    
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

Investigate Vertex AI Model Latency Performance Issues
    [Documentation]    Analyzes latency metrics to identify performance bottlenecks and degradation using Python SDK
    [Tags]    vertex-ai    latency    performance    analysis
    RW.Core.Add Pre To Report    Investigating Vertex AI Model Garden latency performance...
    
    # Analyze latency performance using Python script
    ${latency_analysis}=    RW.CLI.Run Cli
    ...    cmd=python3 vertex_ai_monitoring.py latency --hours 2
    ...    env=${env}
    ...    secret_file__gcp_credentials_json=${gcp_credentials_json}
    ...    show_in_rwl_cheatsheet=true
    ...    timeout_seconds=240
    
    RW.Core.Add To Report    ${latency_analysis.stdout}
    RW.Core.Add Pre To Report    Commands Used:\n${latency_analysis.cmd}
    
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

Monitor Vertex AI Throughput and Token Consumption Patterns
    [Documentation]    Analyzes throughput consumption and token usage patterns for capacity planning using Python SDK
    [Tags]    vertex-ai    throughput    tokens    capacity-planning
    RW.Core.Add Pre To Report    Monitoring Vertex AI Model Garden throughput and token consumption...
    
    # Analyze throughput and token consumption using Python script
    ${throughput_analysis}=    RW.CLI.Run Cli
    ...    cmd=python3 vertex_ai_monitoring.py throughput --hours 2
    ...    env=${env}
    ...    secret_file__gcp_credentials_json=${gcp_credentials_json}
    ...    show_in_rwl_cheatsheet=true
    ...    timeout_seconds=240
    
    RW.Core.Add To Report    ${throughput_analysis.stdout}
    RW.Core.Add Pre To Report    Commands Used:\n${throughput_analysis.cmd}

Check Vertex AI Model Garden API Logs for Issues
    [Documentation]    Analyzes recent API logs for error patterns and usage issues
    [Tags]    vertex-ai    logs    api-calls    monitoring
    RW.Core.Add Pre To Report    Checking Vertex AI Model Garden API logs for issues...
    
    # Use the exact working query from console - Vertex AI errors
    ${vertex_errors}=    RW.CLI.Run Cli
    ...    cmd=gcloud logging read 'resource.type="audited_resource" AND resource.labels.service="aiplatform.googleapis.com" AND severity="ERROR"' --format="json" --freshness="${LOG_FRESHNESS}" --project=${GCP_PROJECT_ID}
    ...    env=${env}
    ...    secret_file__gcp_credentials_json=${gcp_credentials_json}
    ...    show_in_rwl_cheatsheet=true
    ...    timeout_seconds=120
    
    # Check if we got empty results due to permissions
    ${has_vertex_errors}=    Run Keyword And Return Status    Should Not Be Empty    ${vertex_errors.stdout}
    ${empty_result}=    Run Keyword And Return Status    Should Be Equal    ${vertex_errors.stdout}    []\n
    
    IF    ${empty_result}
        RW.Core.Add Issue    
        ...    title=Unable to access audit logs - missing permissions    
        ...    severity=2    
        ...    expected=Service account should have audit log access    
        ...    actual=Service account may be missing roles/logging.privateLogViewer permission    
        ...    reproduce_hint=Grant roles/logging.privateLogViewer to the service account to access audit logs
        ...    next_steps=Grant roles/logging.privateLogViewer role to the service account used by this robot
        RW.Core.Add To Report    ⚠️ Empty audit log results - service account may need roles/logging.privateLogViewer permission
        RETURN
    END
    
    # Parse the vertex errors we found
    ${vertex_error_count}=    Set Variable    0
    ${auth_error_count}=    Set Variable    0
    ${quota_error_count}=    Set Variable    0
    ${service_unavailable_count}=    Set Variable    0
    
    # Count total errors
    ${vertex_count_result}=    RW.CLI.Run Cli
    ...    cmd=echo '${vertex_errors.stdout}' | jq '. | length'
    ...    env=${env}
    ${vertex_error_count}=    Convert To Number    ${vertex_count_result.stdout}
    
    # Check for specific error types
    ${auth_errors}=    RW.CLI.Run Cli
    ...    cmd=echo '${vertex_errors.stdout}' | jq '[.[] | select(.protoPayload.status.code == 7 or .protoPayload.status.code == 16)] | length'
    ...    env=${env}
    ${auth_error_count}=    Convert To Number    ${auth_errors.stdout}
    
    ${quota_errors}=    RW.CLI.Run Cli
    ...    cmd=echo '${vertex_errors.stdout}' | jq '[.[] | select(.protoPayload.status.code == 8)] | length'
    ...    env=${env}
    ${quota_error_count}=    Convert To Number    ${quota_errors.stdout}
    
    # Check for service unavailable errors (code 14)
    ${service_errors}=    RW.CLI.Run Cli
    ...    cmd=echo '${vertex_errors.stdout}' | jq '[.[] | select(.protoPayload.status.code == 14)] | length'
    ...    env=${env}
    ${service_unavailable_count}=    Convert To Number    ${service_errors.stdout}
    
    # Count ChatCompletions vs Predict calls
    ${chat_error_count}=    RW.CLI.Run Cli
    ...    cmd=echo '${vertex_errors.stdout}' | jq '[.[] | select(.protoPayload.methodName == "google.cloud.aiplatform.v1.PredictionService.ChatCompletions")] | length'
    ...    env=${env}
    ${chat_error_count}=    Convert To Number    ${chat_error_count.stdout}
    
    ${predict_error_count}=    RW.CLI.Run Cli
    ...    cmd=echo '${vertex_errors.stdout}' | jq '[.[] | select(.protoPayload.methodName == "google.cloud.aiplatform.v1.PredictionService.Predict")] | length'
    ...    env=${env}
    ${predict_error_count}=    Convert To Number    ${predict_error_count.stdout}
    
    # Report findings
    RW.Core.Add To Report    📋 VERTEX AI ERROR LOG ANALYSIS (Last ${LOG_FRESHNESS})
    RW.Core.Add To Report    • Total Vertex AI Errors: ${vertex_error_count}
    RW.Core.Add To Report    • ChatCompletions errors: ${chat_error_count}
    RW.Core.Add To Report    • Predict API errors: ${predict_error_count}
    RW.Core.Add To Report    • Authentication errors (code 7,16): ${auth_error_count}
    RW.Core.Add To Report    • Quota exceeded errors (code 8): ${quota_error_count}
    RW.Core.Add To Report    • Service unavailable errors (code 14): ${service_unavailable_count}
    
    # Include detailed log entries if we found errors
    IF    ${vertex_error_count} > 0
        RW.Core.Add To Report    ${EMPTY}
        RW.Core.Add To Report    📝 DETAILED ERROR LOGS:
        
        # Format the logs with timestamps, endpoints, and key details
        ${formatted_logs}=    RW.CLI.Run Cli
        ...    cmd=echo '${vertex_errors.stdout}' | jq -r '.[] | "🕐 " + .timestamp + " | " + .protoPayload.methodName + " | Endpoint: " + (.protoPayload.resourceName // "unknown") + " | Code: " + (.protoPayload.status.code | tostring) + " | " + .protoPayload.status.message + " | Caller: " + .protoPayload.authenticationInfo.principalEmail'
        ...    env=${env}
        
        @{log_lines}=    Split String    ${formatted_logs.stdout}    \n
        FOR    ${log_line}    IN    @{log_lines}
            ${log_line}=    Strip String    ${log_line}
            IF    '${log_line}' != ''
                RW.Core.Add To Report    ${log_line}
            END
        END
        
        RW.Core.Add To Report    ${EMPTY}
        RW.Core.Add To Report    📊 ERROR BREAKDOWN BY TYPE:
        
        # Show service unavailable details if present
        IF    ${service_unavailable_count} > 0
            ${service_unavailable_details}=    RW.CLI.Run Cli
            ...    cmd=echo '${vertex_errors.stdout}' | jq -r '.[] | select(.protoPayload.status.code == 14) | "• " + .timestamp + " - " + .protoPayload.methodName + " - " + .protoPayload.status.message'
            ...    env=${env}
            RW.Core.Add To Report    Service Unavailable Errors (${service_unavailable_count}):
            @{service_lines}=    Split String    ${service_unavailable_details.stdout}    \n
            FOR    ${service_line}    IN    @{service_lines}
                ${service_line}=    Strip String    ${service_line}
                IF    '${service_line}' != ''
                    RW.Core.Add To Report    ${service_line}
                END
            END
        END
        
        # Show auth errors if present
        IF    ${auth_error_count} > 0
            ${auth_error_details}=    RW.CLI.Run Cli
            ...    cmd=echo '${vertex_errors.stdout}' | jq -r '.[] | select(.protoPayload.status.code == 7 or .protoPayload.status.code == 16) | "• " + .timestamp + " - " + .protoPayload.methodName + " - " + .protoPayload.status.message'
            ...    env=${env}
            RW.Core.Add To Report    Authentication Errors (${auth_error_count}):
            @{auth_lines}=    Split String    ${auth_error_details.stdout}    \n
            FOR    ${auth_line}    IN    @{auth_lines}
                ${auth_line}=    Strip String    ${auth_line}
                IF    '${auth_line}' != ''
                    RW.Core.Add To Report    ${auth_line}
                END
            END
        END
        
        # Show quota errors if present
        IF    ${quota_error_count} > 0
            ${quota_error_details}=    RW.CLI.Run Cli
            ...    cmd=echo '${vertex_errors.stdout}' | jq -r '.[] | select(.protoPayload.status.code == 8) | "• " + .timestamp + " - " + .protoPayload.methodName + " - " + .protoPayload.status.message'
            ...    env=${env}
            RW.Core.Add To Report    Quota Exceeded Errors (${quota_error_count}):
            @{quota_lines}=    Split String    ${quota_error_details.stdout}    \n
            FOR    ${quota_line}    IN    @{quota_lines}
                ${quota_line}=    Strip String    ${quota_line}
                IF    '${quota_line}' != ''
                    RW.Core.Add To Report    ${quota_line}
                END
            END
        END
    END
    
    # Create issues for problems found with log snippets
    IF    ${vertex_error_count} > 10
        # Get recent log snippets for the issue
        ${recent_logs}=    RW.CLI.Run Cli
        ...    cmd=echo '${vertex_errors.stdout}' | jq -r '.[:5] | .[] | "- " + .timestamp + " | " + .protoPayload.methodName + " | " + (.protoPayload.resourceName // "unknown") + " | Code " + (.protoPayload.status.code | tostring) + ": " + .protoPayload.status.message'
        ...    env=${env}
        
        RW.Core.Add Issue    
        ...    title=High number of Vertex AI errors detected in audit logs    
        ...    severity=1    
        ...    expected=Few or no API errors    
        ...    actual=${vertex_error_count} errors in the last ${LOG_FRESHNESS}    
        ...    details=Recent error examples:\n${recent_logs.stdout}    
        ...    reproduce_hint=Use query: resource.type="audited_resource" AND resource.labels.service="aiplatform.googleapis.com" AND severity="ERROR"
        ...    next_steps=Review error logs for patterns and root causes. Check the Vertex AI audit resource logs for detailed error information.
    ELSE IF    ${vertex_error_count} > 0
        # Get all log snippets for smaller number of errors
        ${all_logs}=    RW.CLI.Run Cli
        ...    cmd=echo '${vertex_errors.stdout}' | jq -r '.[] | "- " + .timestamp + " | " + .protoPayload.methodName + " | " + (.protoPayload.resourceName // "unknown") + " | Code " + (.protoPayload.status.code | tostring) + ": " + .protoPayload.status.message'
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
        ...    cmd=echo '${vertex_errors.stdout}' | jq -r '.[] | select(.protoPayload.status.code == 7 or .protoPayload.status.code == 16) | "- " + .timestamp + " | " + .protoPayload.methodName + " | " + (.protoPayload.resourceName // "unknown") + " | " + .protoPayload.authenticationInfo.principalEmail + " | " + .protoPayload.status.message'
        ...    env=${env}
        
        RW.Core.Add Issue    
        ...    title=Authentication errors detected in Vertex AI logs    
        ...    severity=1    
        ...    expected=No authentication errors    
        ...    actual=${auth_error_count} authentication errors found in logs    
        ...    details=Authentication error details:\n${auth_log_snippets.stdout}    
        ...    reproduce_hint=Use query: resource.type="audited_resource" AND resource.labels.service="aiplatform.googleapis.com" AND severity="ERROR"
        ...    next_steps=Check service account permissions and API key configuration
    END
    
    IF    ${quota_error_count} > 0
        ${quota_log_snippets}=    RW.CLI.Run Cli
        ...    cmd=echo '${vertex_errors.stdout}' | jq -r '.[] | select(.protoPayload.status.code == 8) | "- " + .timestamp + " | " + .protoPayload.methodName + " | " + (.protoPayload.resourceName // "unknown") + " | " + .protoPayload.authenticationInfo.principalEmail + " | " + .protoPayload.status.message'
        ...    env=${env}
        
        RW.Core.Add Issue    
        ...    title=Quota exceeded errors detected in Vertex AI logs    
        ...    severity=1    
        ...    expected=No quota errors    
        ...    actual=${quota_error_count} quota exceeded errors found in logs    
        ...    details=Quota error details:\n${quota_log_snippets.stdout}    
        ...    reproduce_hint=Use query: resource.type="audited_resource" AND resource.labels.service="aiplatform.googleapis.com" AND severity="ERROR"
        ...    next_steps=Review quota limits and request increases if needed
    END
    
    IF    ${service_unavailable_count} > 0
        ${service_log_snippets}=    RW.CLI.Run Cli
        ...    cmd=echo '${vertex_errors.stdout}' | jq -r '.[] | select(.protoPayload.status.code == 14) | "- " + .timestamp + " | " + .protoPayload.methodName + " | " + (.protoPayload.resourceName // "unknown") + " | " + .protoPayload.authenticationInfo.principalEmail + " | " + .protoPayload.status.message'
        ...    env=${env}
        
        RW.Core.Add Issue    
        ...    title=Service unavailable errors detected in Vertex AI logs    
        ...    severity=1    
        ...    expected=Vertex AI service should be available    
        ...    actual=${service_unavailable_count} service unavailable errors found in logs    
        ...    details=Service unavailable error details:\n${service_log_snippets.stdout}    
        ...    reproduce_hint=Use query: resource.type="audited_resource" AND resource.labels.service="aiplatform.googleapis.com" AND severity="ERROR"
        ...    next_steps=Check Vertex AI service status and endpoint availability. The service may be experiencing outages.
    END
    
    RW.Core.Add Pre To Report    Commands Used:\n${vertex_errors.cmd}

Check Vertex AI Model Garden Service Health and Quotas
    [Documentation]    Verifies service availability and quota status for Model Garden using Python SDK
    [Tags]    vertex-ai    service-health    quotas    configuration
    RW.Core.Add Pre To Report    Checking Vertex AI Model Garden service health and quotas...
    
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
    IF    ${api_enabled}
        RW.Core.Add To Report    ✅ Vertex AI API is enabled
    ELSE
        RW.Core.Add To Report    ❌ Vertex AI API is not enabled
        RW.Core.Add Issue    
        ...    title=Vertex AI API not enabled    
        ...    severity=1    
        ...    expected=API should be enabled    
        ...    actual=API not found in enabled services    
        ...    reproduce_hint=Run: gcloud services enable aiplatform.googleapis.com --project=${GCP_PROJECT_ID}
        ...    next_steps=Run: gcloud services enable aiplatform.googleapis.com --project=${GCP_PROJECT_ID}
    END
    
    RW.Core.Add To Report    ${metrics_check.stdout}
    RW.Core.Add Pre To Report    Commands Used:\n${metrics_check.cmd}

Generate Vertex AI Model Garden Health Summary and Next Steps
    [Documentation]    Generates a comprehensive health summary with actionable recommendations
    [Tags]    summary    health-report    recommendations
    RW.Core.Add Pre To Report    Generating comprehensive Vertex AI Model Garden health summary...
    
    ${current_date}=    Get Current Date    result_format=%Y-%m-%d %H:%M:%S UTC
    
    ${summary_report}=    Catenate    SEPARATOR=\n
    ...    📊 VERTEX AI MODEL GARDEN HEALTH SUMMARY
    ...    Project: ${GCP_PROJECT_ID}
    ...    Analysis Period: Last 2 hours
    ...    Timestamp: ${current_date}
    ...    ${EMPTY}
    ...    🔍 RECOMMENDED NEXT STEPS:
    ...    1. Monitor error rates with Cloud Monitoring Python SDK
    ...    2. Check latency trends with dashboard: https://console.cloud.google.com/monitoring/dashboards?project=${GCP_PROJECT_ID}
    ...    3. Review quota usage at: https://console.cloud.google.com/iam-admin/quotas?project=${GCP_PROJECT_ID}
    ...    4. Set up alerting for error rates > 5% and latency > 10s
    ...    5. Monitor token consumption for cost optimization
    ...    ${EMPTY}
    ...    📚 USEFUL DOCUMENTATION:
    ...    - Model Garden Monitoring: https://cloud.google.com/vertex-ai/docs/model-garden/monitor-models
    ...    - Provisioned Throughput: https://cloud.google.com/vertex-ai/generative-ai/docs/provisioned-throughput
    ...    - Error Troubleshooting: https://cloud.google.com/vertex-ai/docs/general/troubleshooting
    ...    - Quota Management: https://cloud.google.com/vertex-ai/quotas
    
    RW.Core.Add To Report    ${summary_report}

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