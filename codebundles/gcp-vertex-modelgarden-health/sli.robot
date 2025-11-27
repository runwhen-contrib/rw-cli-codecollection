*** Settings ***
Documentation       Calculates SLI for GCP Vertex AI Model Garden health using Google Cloud Monitoring Python SDK.
...                 
...                 Required IAM Roles:
...                 - roles/monitoring.viewer (for metrics access)
...                 - roles/logging.privateLogViewer (for quick log health check)
...                 
...                 Required Permissions:
...                 - monitoring.timeSeries.list
...                 - logging.privateLogEntries.list
Metadata            Author    stewartshea
Metadata            Display Name    GCP Vertex AI Model Garden Health SLI
Metadata            Supports    GCP,Vertex AI,Model Garden

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             OperatingSystem
Library             Collections
Library             String

Suite Setup         Suite Initialization

*** Tasks ***
Quick Vertex AI Log Health Check for `${GCP_PROJECT_ID}`
    [Documentation]    Performs a quick check of recent Vertex AI logs for immediate health assessment
    [Tags]    vertex-ai    logs    health-check    quick    access:read-only
    
    Log    Starting Quick Vertex AI Log Health Check for project: ${GCP_PROJECT_ID}
    Log    Looking back ${SLI_LOG_LOOKBACK} for recent errors
    
    # Quick check for recent errors using configurable lookback time
    ${recent_errors}=    RW.CLI.Run Cli
    ...    cmd=gcloud logging read 'resource.type="audited_resource" AND resource.labels.service="aiplatform.googleapis.com" AND severity="ERROR"' --format="json" --freshness="${SLI_LOG_LOOKBACK}" --limit=20 --project=${GCP_PROJECT_ID}
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=60
    
    # Count recent errors
    ${recent_error_count}=    RW.CLI.Run Cli
    ...    cmd=echo '${recent_errors.stdout}' > vertex_errors_sli.json && jq '. | length' vertex_errors_sli.json && rm -f vertex_errors_sli.json
    ...    env=${env}
    ${recent_error_count_result}=    Set Variable    ${recent_error_count.stdout}
    ${conversion_success}=    Run Keyword And Return Status    Convert To Number    ${recent_error_count_result}
    IF    not ${conversion_success}
        Log    Error parsing recent error count (got: '${recent_error_count_result}'), defaulting to 0
        ${recent_error_count}=    Set Variable    0
    ELSE
        ${recent_error_count}=    Convert To Number    ${recent_error_count_result}
    END
    
    Log    Found ${recent_error_count} recent errors in logs
    
    # Calculate log health score (1.0 = no recent errors, decreases with more errors)
    ${log_health_score}=    Set Variable If
    ...    ${recent_error_count} == 0    1.0
    ...    ${recent_error_count} <= 2    0.8
    ...    ${recent_error_count} <= 5    0.6
    ...    ${recent_error_count} <= 10   0.4
    ...    0.2
    
    ${log_health_percentage}=    Evaluate    ${log_health_score} * 100
    ${log_health_status}=    Set Variable If
    ...    ${log_health_score} >= 0.8    Healthy
    ...    ${log_health_score} >= 0.6    Warning
    ...    Critical
    
    Log    Log Health Check (Last ${SLI_LOG_LOOKBACK}): ${recent_error_count} errors, Score: ${log_health_percentage}% (${log_health_status})
    Log    Log health score calculation: ${recent_error_count} errors → ${log_health_score} score
    
    RW.Core.Add To Report    📊 Log Health Check: ${recent_error_count} errors (${SLI_LOG_LOOKBACK}) → Score: ${log_health_score}
    
    Set Global Variable    ${log_health_score}
    RW.Core.Push Metric    ${log_health_score}    sub_name=log_health

Calculate Error Rate Score for `${GCP_PROJECT_ID}`
    [Documentation]    Calculates error rate score based on Model Garden invocation errors
    [Tags]    vertex-ai    error-rate    sli    monitoring    access:read-only
    
    Log    Starting Error Rate Score calculation for project: ${GCP_PROJECT_ID}
    Log    Analyzing last 2 hours of Model Garden metrics with full model discovery
    
    # Get error rate analysis with discovery
    ${error_analysis}=    RW.CLI.Run Cli
    ...    cmd=python3 vertex_ai_monitoring.py errors --hours 2 ${region_args}
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=300
    
    Log    Error analysis output: ${error_analysis.stdout}
    
    # Parse error results
    ${error_count}=    Set Variable    0
    @{output_lines}=    Split String    ${error_analysis.stdout}    \n
    FOR    ${line}    IN    @{output_lines}
        ${line}=    Strip String    ${line}
        IF    'ERROR_COUNT:' in $line
            ${count_part}=    Split String    ${line}    :
            ${error_count}=    Strip String    ${count_part}[1]
            ${error_count}=    Convert To Number    ${error_count}
            Log    Parsed error count from output: ${error_count}
            BREAK
        END
    END
    
    # Calculate error score (1.0 = no errors, decreases with error rate)
    ${error_rate_score}=    Set Variable    1.0
    ${error_rate_display}=    Set Variable    0%
    IF    ${error_count} > 0
        Log    Errors detected, calculating error rate score...
        # Extract error rate from stdout
        @{output_lines}=    Split String    ${error_analysis.stdout}    \n  
        FOR    ${line}    IN    @{output_lines}
            ${contains_rate}=    Run Keyword And Return Status    Should Contain    ${line}    Error Rate:
            IF    ${contains_rate}
                ${rate_parts}=    Split String    ${line}    :
                ${rate_with_percent}=    Strip String    ${rate_parts}[1]
                ${rate_str}=    Replace String    ${rate_with_percent}    %    ${EMPTY}
                ${error_rate}=    Convert To Number    ${rate_str}
                ${error_rate_display}=    Set Variable    ${error_rate}%
                Log    Parsed error rate: ${error_rate}%
                # Score: 1.0 for 0%, 0.8 for 1-5%, 0.5 for 5-10%, 0.2 for 10-20%, 0.0 for >20%
                IF    ${error_rate} == 0
                    ${error_rate_score}=    Set Variable    1.0
                ELSE IF    ${error_rate} <= 5
                    ${error_rate_score}=    Set Variable    0.8
                ELSE IF    ${error_rate} <= 10
                    ${error_rate_score}=    Set Variable    0.5
                ELSE IF    ${error_rate} <= 20
                    ${error_rate_score}=    Set Variable    0.2
                ELSE
                    ${error_rate_score}=    Set Variable    0.0
                END
                Log    Error rate ${error_rate}% mapped to score: ${error_rate_score}
                BREAK
            END
        END
    ELSE
        Log    No errors detected, using perfect score: 1.0
    END
    
    Log    Error Rate Score: ${error_rate_score} (${error_count} errors detected)
    RW.Core.Add To Report    📊 Error Rate Score: ${error_count} errors, ${error_rate_display} rate → Score: ${error_rate_score}
    Set Global Variable    ${error_rate_score}
    RW.Core.Push Metric    ${error_rate_score}    sub_name=error_rate

Calculate Latency Performance Score for `${GCP_PROJECT_ID}`
    [Documentation]    Calculates latency performance score based on model response times
    [Tags]    vertex-ai    latency    performance    sli    access:read-only
    
    Log    Starting Latency Performance Score calculation for project: ${GCP_PROJECT_ID}
    Log    Analyzing last 2 hours of model latency metrics with full model discovery
    
    # Get latency analysis with discovery
    ${latency_analysis}=    RW.CLI.Run Cli
    ...    cmd=python3 vertex_ai_monitoring.py latency --hours 2 ${region_args}
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=300
    
    Log    Latency analysis output: ${latency_analysis.stdout}
    
    # Parse latency results
    ${high_latency_count}=    Set Variable    0
    ${elevated_latency_count}=    Set Variable    0
    
    @{output_lines}=    Split String    ${latency_analysis.stdout}    \n
    FOR    ${line}    IN    @{output_lines}
        ${line}=    Strip String    ${line}
        IF    'HIGH_LATENCY_MODELS:' in $line
            ${count_part}=    Split String    ${line}    :
            ${high_latency_count}=    Strip String    ${count_part}[1]
            ${high_latency_count}=    Convert To Number    ${high_latency_count}
            Log    Parsed high latency models count: ${high_latency_count}
        ELSE IF    'ELEVATED_LATENCY_MODELS:' in $line  
            ${count_part}=    Split String    ${line}    :
            ${elevated_latency_count}=    Strip String    ${count_part}[1]
            ${elevated_latency_count}=    Convert To Number    ${elevated_latency_count}
            Log    Parsed elevated latency models count: ${elevated_latency_count}
        END
    END
    
    # Calculate latency score based on model performance
    ${total_models}=    Set Variable    0
    ${good_models}=    Set Variable    0
    
    Log    Analyzing individual model performance...
    @{output_lines}=    Split String    ${latency_analysis.stdout}    \n
    FOR    ${line}    IN    @{output_lines}
        ${is_model_line}=    Run Keyword And Return Status    Should Match Regexp    ${line}    ^\\s+\\w+.*:\\s+\\d+\\.\\d+s avg
        IF    ${is_model_line}
            ${total_models}=    Evaluate    ${total_models} + 1
            # Check if model has good performance (not "Poor" or "Fair-Poor")
            ${is_good}=    Run Keyword And Return Status    Should Not Contain Any    ${line}    Poor    Fair-Poor
            IF    ${is_good}
                ${good_models}=    Evaluate    ${good_models} + 1
            END
            Log    Model performance line: ${line} → Good: ${is_good}
        END
    END
    
    Log    Total models analyzed: ${total_models}, Good performing models: ${good_models}
    
    ${latency_performance_score}=    Set Variable    1.0
    IF    ${total_models} > 0
        ${latency_performance_score}=    Evaluate    ${good_models} / ${total_models}
        Log    Calculated latency performance score: ${good_models}/${total_models} = ${latency_performance_score}
    ELSE
        Log    No models found for latency analysis, using default score: 1.0
    END
    
    Log    Latency Performance Score: ${latency_performance_score} (${good_models}/${total_models} models performing well)
    RW.Core.Add To Report    📊 Latency Performance Score: ${good_models}/${total_models} models good → Score: ${latency_performance_score}
    Set Global Variable    ${latency_performance_score}
    RW.Core.Push Metric    ${latency_performance_score}    sub_name=latency_performance

Calculate Throughput Usage Score for `${GCP_PROJECT_ID}`
    [Documentation]    Calculates throughput usage score based on token consumption data
    [Tags]    vertex-ai    throughput    usage    sli    access:read-only
    
    Log    Starting Throughput Usage Score calculation for project: ${GCP_PROJECT_ID}
    Log    Analyzing last 2 hours of token consumption data with full model discovery
    
    # Get throughput analysis with discovery
    ${throughput_analysis}=    RW.CLI.Run Cli
    ...    cmd=python3 vertex_ai_monitoring.py throughput --hours 2 ${region_args}
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=300
    
    Log    Throughput analysis output: ${throughput_analysis.stdout}
    
    # Calculate throughput score (1.0 if has usage data, 0.5 if no data)
    ${has_usage}=    Run Keyword And Return Status    Should Contain    ${throughput_analysis.stdout}    HAS_USAGE_DATA:true
    ${throughput_usage_score}=    Set Variable If    ${has_usage}    1.0    0.5
    
    # Check if we discovered models even without usage data
    ${models_discovered}=    Set Variable    0
    @{output_lines}=    Split String    ${throughput_analysis.stdout}    \n
    FOR    ${line}    IN    @{output_lines}
        ${line}=    Strip String    ${line}
        IF    'MODELS_DISCOVERED:' in $line
            ${count_part}=    Split String    ${line}    :
            ${models_discovered}=    Strip String    ${count_part}[1]
            ${models_discovered}=    Convert To Number    ${models_discovered}
            Log    Parsed discovered models count: ${models_discovered}
            BREAK
        END
    END
    
    # Adjust score based on discovery results
    IF    not ${has_usage} and ${models_discovered} > 0
        ${throughput_usage_score}=    Set Variable    0.7
        Log    No usage data but ${models_discovered} models discovered, adjusted score to 0.7
    END
    
    Log    Usage data detected: ${has_usage}
    Log    Models discovered: ${models_discovered}
    Log    Throughput score calculation: Usage data available → ${throughput_usage_score}
    Log    Throughput Usage Score: ${throughput_usage_score} (Usage data available: ${has_usage}, Models discovered: ${models_discovered})
    RW.Core.Add To Report    📊 Throughput Usage Score: Usage data (${has_usage}), Models discovered (${models_discovered}) → Score: ${throughput_usage_score}
    Set Global Variable    ${throughput_usage_score}
    RW.Core.Push Metric    ${throughput_usage_score}    sub_name=throughput_usage

Discover All Deployed Models for `${GCP_PROJECT_ID}`
    [Documentation]    Proactively discovers all deployed Vertex AI models and endpoints
    [Tags]    vertex-ai    discovery    model-inventory    access:read-only
    
    Log    Starting Proactive Model Discovery for project: ${GCP_PROJECT_ID}
    Log    Discovering all deployed models across all regions
    
    # Get full model discovery
    ${discovery_results}=    RW.CLI.Run Cli
    ...    cmd=python3 vertex_ai_monitoring.py discover ${region_args}
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=300
    
    Log    Discovery results: ${discovery_results.stdout}
    
    # Parse discovery results
    ${models_discovered}=    Set Variable    0
    ${endpoints_discovered}=    Set Variable    0
    
    @{output_lines}=    Split String    ${discovery_results.stdout}    \n
    FOR    ${line}    IN    @{output_lines}
        ${line}=    Strip String    ${line}
        IF    'ALL_MODELS_DISCOVERED:' in $line
            ${count_part}=    Split String    ${line}    :
            ${models_discovered}=    Strip String    ${count_part}[1]
            ${models_discovered}=    Convert To Number    ${models_discovered}
            Log    Parsed models discovered: ${models_discovered}
        ELSE IF    'ALL_ENDPOINTS_DISCOVERED:' in $line
            ${count_part}=    Split String    ${line}    :
            ${endpoints_discovered}=    Strip String    ${count_part}[1]
            ${endpoints_discovered}=    Convert To Number    ${endpoints_discovered}
            Log    Parsed endpoints discovered: ${endpoints_discovered}
        END
    END
    
    # Calculate discovery score
    ${discovery_score}=    Set Variable If    ${models_discovered} > 0    1.0    0.0
    
    Log    Model Discovery Results: ${models_discovered} models, ${endpoints_discovered} endpoints
    RW.Core.Add To Report    📊 Model Discovery: ${models_discovered} models, ${endpoints_discovered} endpoints → Score: ${discovery_score}
    
    # Check for LLAMA models specifically
    ${llama_detected}=    Run Keyword And Return Status    Should Contain    ${discovery_results.stdout}    LLAMA MODEL DETECTED
    IF    ${llama_detected}
        Log    🎯 LLAMA MODEL FOUND in discovery results!
        RW.Core.Add To Report    🎯 LLAMA MODEL DETECTED: Your llama-3-1-8b-instruct-mg-one-click-deploy model was found!
    END
    
    Set Global Variable    ${discovery_score}
    Set Global Variable    ${models_discovered}
    Set Global Variable    ${endpoints_discovered}
    RW.Core.Push Metric    ${discovery_score}    sub_name=model_discovery

Check Service Availability Score for `${GCP_PROJECT_ID}`
    [Documentation]    Checks Vertex AI service availability and configuration
    [Tags]    vertex-ai    service-health    availability    sli    access:read-only
    
    Log    Starting Service Availability Score check for project: ${GCP_PROJECT_ID}
    Log    Checking Vertex AI API enablement and metrics availability
    
    # Check if Vertex AI services are enabled
    ${service_status}=    RW.CLI.Run Cli
    ...    cmd=gcloud services list --enabled --filter="name:aiplatform.googleapis.com" --format="table[no-heading](name)" --project=${GCP_PROJECT_ID}
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    
    Log    Service status check output: ${service_status.stdout}
    
    # Check service health using Python script
    ${metrics_check}=    RW.CLI.Run Cli
    ...    cmd=python3 vertex_ai_monitoring.py health
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    
    Log    Metrics availability check output: ${metrics_check.stdout}
    
    ${api_enabled}=    Run Keyword And Return Status    Should Contain    ${service_status.stdout}    aiplatform.googleapis.com
    Log    Vertex AI API enabled: ${api_enabled}
    
    # Parse metrics availability
    ${metrics_available}=    Set Variable    0
    @{output_lines}=    Split String    ${metrics_check.stdout}    \n
    FOR    ${line}    IN    @{output_lines}
        ${line}=    Strip String    ${line}
        IF    'METRICS_AVAILABLE:' in $line
            ${count_part}=    Split String    ${line}    :
            ${metrics_available}=    Strip String    ${count_part}[1]
            ${metrics_available}=    Convert To Number    ${metrics_available}
            Log    Parsed metrics available count: ${metrics_available}
            BREAK
        END
    END
    
    # Calculate service availability score
    ${service_availability_score}=    Set Variable If
    ...    ${api_enabled} and ${metrics_available} > 0    1.0
    ...    ${api_enabled}    0.5
    ...    0.0
    
    Log    Service availability score calculation: API enabled (${api_enabled}) + Metrics available (${metrics_available}) → ${service_availability_score}
    Log    Service Availability Score: ${service_availability_score} (API enabled: ${api_enabled}, Metrics available: ${metrics_available})
    RW.Core.Add To Report    📊 Service Availability Score: API enabled (${api_enabled}), Metrics (${metrics_available}) → Score: ${service_availability_score}
    Set Global Variable    ${service_availability_score}
    RW.Core.Push Metric    ${service_availability_score}    sub_name=service_availability

Generate Final Vertex AI Model Garden Health Score for `${GCP_PROJECT_ID}`
    [Documentation]    Generates final composite health score from all individual measurements
    [Tags]    vertex-ai    health-score    sli    final-score
    
    Log    Starting Final Health Score calculation for project: ${GCP_PROJECT_ID}
    Log    Aggregating all component scores...
    
    # Log all component scores before calculation
    Log    Component Score Summary:
    Log    • Log Health Score: ${log_health_score}
    Log    • Error Rate Score: ${error_rate_score}
    Log    • Latency Performance Score: ${latency_performance_score}
    Log    • Throughput Usage Score: ${throughput_usage_score}
    Log    • Service Availability Score: ${service_availability_score}
    
    # Calculate final composite health score by averaging all component scores
    ${final_health_score}=    Evaluate    (${log_health_score} + ${error_rate_score} + ${latency_performance_score} + ${throughput_usage_score} + ${service_availability_score}) / 5
    ${final_health_score}=    Evaluate    round(${final_health_score}, 3)
    
    Log    Final score calculation: (${log_health_score} + ${error_rate_score} + ${latency_performance_score} + ${throughput_usage_score} + ${service_availability_score}) / 5 = ${final_health_score}
    
    # Convert to percentage for logging
    ${health_percentage}=    Evaluate    ${final_health_score} * 100
    ${health_percentage}=    Evaluate    round(${health_percentage}, 1)
    
    # Determine health status
    ${health_status}=    Set Variable If
    ...    ${final_health_score} >= 0.9    Excellent
    ...    ${final_health_score} >= 0.7    Good  
    ...    ${final_health_score} >= 0.5    Fair
    ...    ${final_health_score} >= 0.3    Poor
    ...    Critical
    
    # Consolidate final health score report
    ${consolidated_health_report}=    Catenate    SEPARATOR=\n
    ...    🏆 FINAL VERTEX AI MODEL GARDEN HEALTH SCORE
    ...    ═══════════════════════════════════════════════════
    ...    Overall Health: ${health_percentage}% (${health_status})
    ...    ${EMPTY}
    ...    📊 COMPONENT SCORES:
    ...    • Log Health: ${log_health_score}
    ...    • Error Rate: ${error_rate_score}
    ...    • Latency Performance: ${latency_performance_score}
    ...    • Throughput Usage: ${throughput_usage_score}
    ...    • Service Availability: ${service_availability_score}
    ...    ${EMPTY}
    ...    🚀 Pushing Health Score: ${final_health_score}
    
    RW.Core.Add Pre To Report    ${consolidated_health_report}
    
    # Push the final SLI metric
    RW.Core.Push Metric    ${final_health_score}

*** Keywords ***
Suite Initialization
    ${gcp_credentials}=    RW.Core.Import Secret    gcp_credentials
    ...    type=string
    ...    description=GCP service account json used to authenticate with GCP APIs.
    ...    pattern=\w*
    ...    example={"type": "service_account","project_id":"myproject-ID", ... super secret stuff ...}
    ${GCP_PROJECT_ID}=    RW.Core.Import User Variable    GCP_PROJECT_ID
    ...    type=string
    ...    description=The GCP Project ID to scope the API to.
    ...    pattern=\w*
    ...    example=myproject-ID
    ${SLI_LOG_LOOKBACK}=    RW.Core.Import User Variable    SLI_LOG_LOOKBACK
    ...    type=string
    ...    description=Time window for SLI log health check (e.g., 15m, 30m, 1h).
    ...    pattern=\w*
    ...    example=15m
    ...    default=15m
    ${VERTEX_AI_REGIONS}=    RW.Core.Import User Variable    VERTEX_AI_REGIONS
    ...    type=string
    ...    description=Comma-separated list of regions to check for model discovery (optional). Use 'fast' for common US regions, 'us-only' for all US regions, 'priority' for worldwide common regions.
    ...    pattern=\w*
    ...    example=us-central1,us-east4,us-east5
    ...    default=
    ${OS_PATH}=    Get Environment Variable    PATH
    Set Suite Variable    ${GCP_PROJECT_ID}    ${GCP_PROJECT_ID}
    Set Suite Variable    ${SLI_LOG_LOOKBACK}    ${SLI_LOG_LOOKBACK}
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