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
Checking HTTP URL Is Available And Timely
    [Documentation]    Use cURL to validate the http response  
    [Tags]    cURL    HTTP    Ingress    Latency    Errors
    ${curl_rsp}=    RW.CLI.Run Cli
    ...    cmd=curl -o /dev/null -w '{"http_code": \%{http_code}, "time_total": \%{time_total}}' -s ${URL}
    ${json}=    evaluate  json.loads($curl_rsp.stdout)
    ${latency}=    Set Variable    ${json['time_total']}
    ${latency_within_target}=    Evaluate    1 if ${latency} <= ${TARGET_LATENCY} else 0
    ${status_code}=    Set Variable    ${json['http_code']}
    ${http_ok}=    Evaluate    1 if ${status_code} == ${DESIRED_RESPONSE_CODE} else 0
    ${score}=    Evaluate    int(${latency_within_target}*${http_ok})
    RW.Core.Push Metric    ${score}
