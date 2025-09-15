*** Settings ***
Documentation       This taskset uses curl to validate the response code of the endpoint. Returns ascore of 1 if healthy, an 0 if unhealthy. 
Metadata            Author    stewartshea
Metadata            Display Name    cURL HTTP OK
Metadata            Supports    Linux macOS Windows HTTP
Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform


Suite Setup         Suite Initialization


*** Keywords ***
Suite Initialization
    ${URL}=    RW.Core.Import User Variable    URL
    ...    type=string
    ...    description=What URL to perform requests against.
    ...    pattern=\w*
    ...    default=https://www.runwhen.com
    ...    example=https://www.runwhen.com
    ${TARGET_LATENCY}=    RW.Core.Import User Variable    TARGET_LATENCY
    ...    type=string
    ...    description=The maximum latency in seconds as a float value allowed for requests to have.
    ...    pattern=\w*
    ...    default=1.2
    ...    example=1.2
    ${DESIRED_RESPONSE_CODE}=    RW.Core.Import User Variable    DESIRED_RESPONSE_CODE
    ...    type=string
    ...    description=The response code that indicates success.
    ...    pattern=\w*
    ...    default=200
    ...    example=200
*** Tasks ***
Validate HTTP URL Availability and Timeliness for ${URL}
    [Documentation]    Use cURL to validate the http response  
    [Tags]    cURL    HTTP    Ingress    Latency    Errors
    ${curl_rsp}=    RW.CLI.Run Cli
    ...    cmd=curl --connect-timeout 5 --max-time 15 -L -o /dev/null -w '{"http_code": "\%{http_code}", "time_total": \%{time_total}, "curl_exit_code": \%{exitcode}}' -s ${URL}
    
    # Check curl command success first (before JSON parsing)
    ${curl_success}=    Evaluate    1 if ${curl_rsp.returncode} == 0 else 0
    
    # Initialize default values for failed curl commands
    ${latency}=    Set Variable    0
    ${status_code}=    Set Variable    000
    ${connection_success}=    Set Variable    0
    ${http_ok}=    Set Variable    0
    ${latency_within_target}=    Set Variable    0
    
    # Only parse JSON if curl succeeded and stdout is not empty
    IF    ${curl_success} == 1 and $curl_rsp.stdout != ""
        TRY
            ${json}=    Evaluate    json.loads(r'''${curl_rsp.stdout}''')    json
            ${latency}=    Set Variable    ${json['time_total']}
            ${status_code}=    Set Variable    ${json['http_code']}
            
            # Check for connection failures (HTTP 000 status code)
            ${connection_success}=    Evaluate    1 if "${status_code}" != "000" else 0
            
            # Check if HTTP status code matches desired response code
            ${http_ok}=    Evaluate    1 if "${status_code}" == "${DESIRED_RESPONSE_CODE}" else 0
            
            # Check if latency is within target
            ${latency_within_target}=    Evaluate    1 if ${latency} <= ${TARGET_LATENCY} else 0
        EXCEPT
            # JSON parsing failed - treat as connection failure
            Log    Failed to parse JSON from curl output: ${curl_rsp.stdout}
        END
    ELSE
        # Curl failed or no output - already set defaults above
        Log    Curl command failed with return code: ${curl_rsp.returncode}
    END
    
    # Overall health score: all conditions must be met for a score of 1
    # If curl fails or connection fails (000), score is 0 regardless of other factors
    ${score}=    Evaluate    int(${curl_success} * ${connection_success} * ${http_ok} * ${latency_within_target})
    
    # Push individual metrics for better observability
    RW.Core.Push Metric    ${curl_success}    sub_name=curl_success
    RW.Core.Push Metric    ${connection_success}    sub_name=connection_success
    RW.Core.Push Metric    ${http_ok}    sub_name=http_status_ok
    RW.Core.Push Metric    ${latency_within_target}    sub_name=latency_ok
    RW.Core.Push Metric    ${score}    sub_name=http_health
    RW.Core.Push Metric    ${score}
