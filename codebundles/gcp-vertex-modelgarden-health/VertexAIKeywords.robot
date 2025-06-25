*** Settings ***
Documentation    Custom keywords for Vertex AI Model Garden monitoring using Python utilities
Library          RW.CLI
Library          BuiltIn
Library          String
Library          Collections

*** Keywords ***
Analyze Model Garden Error Patterns
    [Documentation]    Analyzes error patterns and response codes from Model Garden invocations
    [Arguments]    ${hours}=2
    
    ${result}=    RW.CLI.Run Cli
    ...    cmd=python3 ${CURDIR}/vertex_ai_monitoring.py errors --hours ${hours}
    ...    env=${env}
    ...    secret_file__gcp_credentials_json=${gcp_credentials_json}
    
    RETURN    ${result}

Analyze Model Garden Latency Performance
    [Documentation]    Analyzes latency metrics to identify performance bottlenecks
    [Arguments]    ${hours}=2
    
    ${result}=    RW.CLI.Run Cli
    ...    cmd=python3 ${CURDIR}/vertex_ai_monitoring.py latency --hours ${hours}
    ...    env=${env}
    ...    secret_file__gcp_credentials_json=${gcp_credentials_json}
    
    RETURN    ${result}

Analyze Model Garden Throughput Consumption
    [Documentation]    Analyzes throughput consumption and token usage patterns
    [Arguments]    ${hours}=2
    
    ${result}=    RW.CLI.Run Cli
    ...    cmd=python3 ${CURDIR}/vertex_ai_monitoring.py throughput --hours ${hours}
    ...    env=${env}
    ...    secret_file__gcp_credentials_json=${gcp_credentials_json}
    
    RETURN    ${result}

Check Model Garden Service Health
    [Documentation]    Verifies service availability and quota status for Model Garden
    
    ${result}=    RW.CLI.Run Cli
    ...    cmd=python3 ${CURDIR}/vertex_ai_monitoring.py health
    ...    env=${env}
    ...    secret_file__gcp_credentials_json=${gcp_credentials_json}
    
    RETURN    ${result}

Parse Error Analysis Results
    [Documentation]    Parses error analysis output and extracts key metrics
    [Arguments]    ${output}
    
    ${high_error_rate}=    Run Keyword And Return Status    Should Contain    ${output}    HIGH_ERROR_RATE:true
    ${error_count}=    Set Variable    0
    
    @{output_lines}=    Split String    ${output}    \n
    FOR    ${line}    IN    @{output_lines}
        ${line}=    Strip String    ${line}
        IF    'ERROR_COUNT:' in '${line}'
            ${count_part}=    Split String    ${line}    :
            ${error_count}=    Strip String    ${count_part}[1]
            ${error_count}=    Convert To Number    ${error_count}
            BREAK
        END
    END
    
    ${results}=    Create Dictionary
    ...    high_error_rate=${high_error_rate}
    ...    error_count=${error_count}
    
    RETURN    ${results}

Parse Latency Analysis Results
    [Documentation]    Parses latency analysis output and extracts key metrics
    [Arguments]    ${output}
    
    ${high_latency_count}=    Set Variable    0
    ${elevated_latency_count}=    Set Variable    0
    
    @{output_lines}=    Split String    ${output}    \n
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
    
    ${results}=    Create Dictionary
    ...    high_latency_count=${high_latency_count}
    ...    elevated_latency_count=${elevated_latency_count}
    
    RETURN    ${results} 