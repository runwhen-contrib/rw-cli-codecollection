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
    ...    description=What URL to perform requests against (single URL for backward compatibility).
    ...    pattern=\w*
    ...    default=https://www.runwhen.com
    ...    example=https://www.runwhen.com
    ${URLS}=    RW.Core.Import User Variable    URLS
    ...    type=string
    ...    description=Comma-separated list of URLs to perform requests against. If provided, overrides URL variable.
    ...    pattern=\w*
    ...    default=
    ...    example=https://www.runwhen.com,https://api.runwhen.com
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
Validate HTTP URL Availability and Timeliness
    [Documentation]    Use cURL to validate single or multiple http responses
    [Tags]    cURL    HTTP    Ingress    Latency    Errors
    
    # Determine which URLs to test
    ${urls_to_test}=    Set Variable    ${URL}
    IF    "${URLS}" != ""
        ${urls_to_test}=    Set Variable    ${URLS}
    END
    
    # Split URLs by comma and clean whitespace
    ${url_list}=    Evaluate    [url.strip() for url in "${urls_to_test}".split(',') if url.strip()]
    
    # Initialize overall health tracking
    ${overall_healthy}=    Set Variable    1
    ${total_urls}=    Get Length    ${url_list}
    ${healthy_urls}=    Set Variable    0
    
    # Test each URL
    FOR    ${url}    IN    @{url_list}
        ${url_healthy}=    Test Single URL    ${url}
        IF    ${url_healthy} == 1
            ${healthy_urls}=    Evaluate    ${healthy_urls} + 1
        ELSE
            ${overall_healthy}=    Set Variable    0
        END
    END
    
    # Push metrics
    RW.Core.Push Metric    ${overall_healthy}    sub_name=overall_health
    RW.Core.Push Metric    ${overall_healthy}

*** Keywords ***
Test Single URL
    [Documentation]    Test a single URL and return health score
    [Arguments]    ${test_url}
    
    ${curl_rsp}=    RW.CLI.Run Cli
    ...    cmd=curl --connect-timeout 5 --max-time 15 -L -o /dev/null -w '{"http_code": "\%{http_code}", "time_total": \%{time_total}, "curl_exit_code": \%{exitcode}}' -s ${test_url}
    
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
            Log    Failed to parse JSON from curl output for ${test_url}: ${curl_rsp.stdout}
        END
    ELSE
        # Curl failed or no output - already set defaults above
        Log    Curl command failed for ${test_url} with return code: ${curl_rsp.returncode}
    END
    
    # Overall health score for this URL: all conditions must be met for a score of 1
    ${url_score}=    Evaluate    int(${curl_success} * ${connection_success} * ${http_ok} * ${latency_within_target})
    
    # Push individual metrics for this URL (sanitize URL for metric name)
    ${url_metric_name}=    Evaluate    "${test_url}".replace("://", "_").replace("/", "_").replace(".", "_").replace("-", "_")
    RW.Core.Push Metric    ${curl_success}    sub_name=curl_success_${url_metric_name}
    RW.Core.Push Metric    ${connection_success}    sub_name=connection_success_${url_metric_name}
    RW.Core.Push Metric    ${http_ok}    sub_name=http_status_ok_${url_metric_name}
    RW.Core.Push Metric    ${latency_within_target}    sub_name=latency_ok_${url_metric_name}
    RW.Core.Push Metric    ${url_score}    sub_name=url_health_${url_metric_name}
    
    [Return]    ${url_score}
