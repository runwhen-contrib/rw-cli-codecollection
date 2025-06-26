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

Check Vertex AI Model Garden Service Health and Quotas
    [Documentation]    Verifies service availability and quota status for Model Garden using Python SDK
    [Tags]    vertex-ai    service-health    quotas    configuration
    RW.Core.Add Pre To Report    Checking Vertex AI Model Garden service health and quotas...
    
    # Check if Vertex AI services are enabled
    ${service_status}=    RW.CLI.Run Cli
    ...    cmd=gcloud auth activate-service-account --key-file=$GOOGLE_APPLICATION_CREDENTIALS && gcloud services list --enabled --filter="name:aiplatform.googleapis.com" --format="table[no-heading](name)" --project=${GCP_PROJECT_ID}
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
    ${OS_PATH}=    Get Environment Variable    PATH
    Set Suite Variable    ${GCP_PROJECT_ID}    ${GCP_PROJECT_ID}
    Set Suite Variable    ${gcp_credentials_json}    ${gcp_credentials_json}
    Set Suite Variable
    ...    ${env}
    ...    {"CLOUDSDK_CORE_PROJECT":"${GCP_PROJECT_ID}","GOOGLE_APPLICATION_CREDENTIALS":"./${gcp_credentials_json.key}","PATH":"$PATH:${OS_PATH}"} 