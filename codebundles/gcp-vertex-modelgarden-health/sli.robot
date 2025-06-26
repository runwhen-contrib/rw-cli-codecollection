*** Settings ***
Documentation       Calculates SLI for GCP Vertex AI Model Garden health using Google Cloud Monitoring Python SDK.
Metadata            Author    runwhen
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
Calculate Vertex AI Model Garden Health Score
    [Documentation]    Calculates a composite health score based on error rate, latency, and throughput metrics using Python SDK
    [Tags]    vertex-ai    health-score    sli    monitoring
    
    # Initialize scores
    ${error_score}=    Set Variable    1.0
    ${latency_score}=    Set Variable    1.0
    ${throughput_score}=    Set Variable    1.0
    
    # Get error rate analysis using direct CLI call
    ${error_analysis}=    RW.CLI.Run Cli
    ...    cmd=python3 vertex_ai_monitoring.py errors --hours 2
    ...    env=${env}
    ...    secret_file__gcp_credentials_json=${gcp_credentials_json}
    ...    show_in_rwl_cheatsheet=true
    ...    timeout_seconds=240
    
    # Parse error results directly
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
    
    # Calculate error score (1.0 = no errors, 0.0 = high errors)
    IF    ${error_count} > 0
        # Extract error rate from stdout
        @{output_lines}=    Split String    ${error_analysis.stdout}    \n
        FOR    ${line}    IN    @{output_lines}
            ${contains_rate}=    Run Keyword And Return Status    Should Contain    ${line}    Error Rate:
            IF    ${contains_rate}
                ${rate_parts}=    Split String    ${line}    :
                ${rate_with_percent}=    Strip String    ${rate_parts}[1]
                ${rate_str}=    Replace String    ${rate_with_percent}    %    ${EMPTY}
                ${error_rate}=    Convert To Number    ${rate_str}
                # Score: 1.0 for 0%, 0.8 for 1-5%, 0.5 for 5-10%, 0.2 for 10-20%, 0.0 for >20%
                IF    ${error_rate} == 0
                    ${error_score}=    Set Variable    1.0
                ELSE IF    ${error_rate} <= 5
                    ${error_score}=    Set Variable    0.8
                ELSE IF    ${error_rate} <= 10
                    ${error_score}=    Set Variable    0.5
                ELSE IF    ${error_rate} <= 20
                    ${error_score}=    Set Variable    0.2
                ELSE
                    ${error_score}=    Set Variable    0.0
                END
                BREAK
            END
        END
    END
    
    # Get latency analysis using direct CLI call
    ${latency_analysis}=    RW.CLI.Run Cli
    ...    cmd=python3 vertex_ai_monitoring.py latency --hours 2
    ...    env=${env}
    ...    secret_file__gcp_credentials_json=${gcp_credentials_json}
    ...    show_in_rwl_cheatsheet=true
    ...    timeout_seconds=240
    
    # Parse latency results directly
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
    
    # Calculate latency score based on model performance
    ${total_models}=    Set Variable    0
    ${good_models}=    Set Variable    0
    
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
        END
    END
    
    IF    ${total_models} > 0
        ${latency_score}=    Evaluate    ${good_models} / ${total_models}
    END
    
    # Get throughput analysis using direct CLI call
    ${throughput_analysis}=    RW.CLI.Run Cli
    ...    cmd=python3 vertex_ai_monitoring.py throughput --hours 2
    ...    env=${env}
    ...    secret_file__gcp_credentials_json=${gcp_credentials_json}
    ...    show_in_rwl_cheatsheet=true
    ...    timeout_seconds=240
    
    # Calculate throughput score (1.0 if has usage data, 0.5 if no data)
    ${has_usage}=    Run Keyword And Return Status    Should Contain    ${throughput_analysis.stdout}    HAS_USAGE_DATA:true
    IF    ${has_usage}
        ${throughput_score}=    Set Variable    1.0
    ELSE
        ${throughput_score}=    Set Variable    0.5
    END
    
    # Calculate weighted composite health score
    # Error rate: 50% weight, Latency: 30% weight, Throughput: 20% weight
    ${health_score}=    Evaluate    (${error_score} * 0.5) + (${latency_score} * 0.3) + (${throughput_score} * 0.2)
    ${health_score}=    Evaluate    round(${health_score}, 3)
    
    # Convert to percentage for display
    ${health_percentage}=    Evaluate    ${health_score} * 100
    ${health_percentage}=    Evaluate    round(${health_percentage}, 1)
    
    # Determine health status
    ${health_status}=    Set Variable If
    ...    ${health_score} >= 0.9    Excellent
    ...    ${health_score} >= 0.7    Good  
    ...    ${health_score} >= 0.5    Fair
    ...    ${health_score} >= 0.3    Poor
    ...    Critical
    
    # Add comprehensive report
    RW.Core.Add To Report    📊 VERTEX AI MODEL GARDEN HEALTH ANALYSIS
    RW.Core.Add To Report    ${EMPTY}
    RW.Core.Add To Report    🎯 Overall Health Score: ${health_percentage}% (${health_status})
    RW.Core.Add To Report    ${EMPTY}
    RW.Core.Add To Report    📈 Component Scores:
    RW.Core.Add To Report    • Error Rate Score: ${error_score} (Weight: 50%)
    RW.Core.Add To Report    • Latency Performance Score: ${latency_score} (Weight: 30%)  
    RW.Core.Add To Report    • Throughput Usage Score: ${throughput_score} (Weight: 20%)
    RW.Core.Add To Report    ${EMPTY}
    RW.Core.Add To Report    📋 Detailed Analysis:
    RW.Core.Add To Report    ${error_analysis.stdout}
    RW.Core.Add To Report    ${EMPTY}
    RW.Core.Add To Report    ${latency_analysis.stdout}
    RW.Core.Add To Report    ${EMPTY}
    RW.Core.Add To Report    ${throughput_analysis.stdout}
    
    # Set the final SLI metric
    RW.Core.Add Pre To Report    Health Score: ${health_score}
    RW.Core.Push Metric    ${health_score}

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