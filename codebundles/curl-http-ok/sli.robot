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
    ...    cmd=curl --connect-timeout 5 --max-time 15 -o /dev/null -w '{"http_code": "\%{http_code}", "time_total": \%{time_total}, "curl_exit_code": \%{exitcode}}' -s ${URL}
    ${json}=    Evaluate    json.loads(r'''${curl_rsp.stdout}''')    json
    ${latency}=    Set Variable    ${json['time_total']}
    ${status_code}=    Set Variable    ${json['http_code']}
    ${curl_exit_code}=    Set Variable    ${json['curl_exit_code']}
    
    # Check for curl command failures (exit code != 0)
    ${curl_success}=    Evaluate    1 if ${curl_exit_code} == 0 else 0
    
    # Check for connection failures (HTTP 000 status code)
    ${connection_success}=    Evaluate    1 if "${status_code}" != "000" else 0
    
    # Check if HTTP status code matches desired response code
    ${http_ok}=    Evaluate    1 if "${status_code}" == "${DESIRED_RESPONSE_CODE}" else 0
    
    # Check if latency is within target
    ${latency_within_target}=    Evaluate    1 if ${latency} <= ${TARGET_LATENCY} else 0
    
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
