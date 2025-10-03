*** Settings ***
Documentation       This taskset uses curl to validate the response code of the endpoint and provides the total time of the request.
Metadata            Author    stewartshea
Metadata            Display Name    cURL HTTP OK
Metadata            Supports    Linux macOS Windows HTTP

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform

Suite Setup         Suite Initialization


*** Tasks ***
Check HTTP URL Availability and Timeliness
    [Documentation]    Use cURL to validate single or multiple http responses
    [Tags]    curl    http    ingress    latency    errors    access:read-only
    
    # Split URLs by comma and clean whitespace
    ${url_list}=    Evaluate    [url.strip() for url in "${URLS}".split(',') if url.strip()]
    
    # Test each URL
    FOR    ${url}    IN    @{url_list}
        Check Single HTTP URL    ${url}
    END

*** Keywords ***
Check Single HTTP URL
    [Documentation]    Use cURL to validate a single http response
    [Arguments]    ${test_url}
    ${curl_rsp}=    RW.CLI.Run Cli
    ...    cmd=curl --connect-timeout 5 --max-time 15 -L -o /dev/null -w '{"http_code": "\%{http_code}", "time_total": \%{time_total}, "curl_exit_code": \%{exitcode}}' -s ${test_url}
    ...    show_in_rwl_cheatsheet=true
    ...    render_in_commandlist=true
    ${owner_kind}=    RW.CLI.Run Cli
                ...    cmd=echo '${OWNER_DETAILS}' | jq -r .kind | sed 's/ *$//' | tr -d '\n'
                ...    include_in_history=False
    ${owner_name}=    RW.CLI.Run Cli
                ...    cmd=echo '${OWNER_DETAILS}' | jq -r .name | sed 's/ *$//' | tr -d '\n'
                ...    include_in_history=False
    ${owner_namespace}=    RW.CLI.Run Cli
                ...    cmd=echo '${OWNER_DETAILS}' | jq -r .namespace | sed 's/ *$//' | tr -d '\n'
                ...    include_in_history=False
    
    # Check curl exit code first - if this fails, it's a connection issue
    IF    ${curl_rsp.returncode} != 0
        ${issue_timestamp}=    RW.Core.Get Issue Timestamp

        RW.Core.Add Issue
        ...    severity=2
        ...    title=HTTP connection failed for ${owner_kind.stdout} `${owner_name.stdout}` - curl command failed for ${test_url}
        ...    expected=Curl command should succeed with exit code 0
        ...    actual=Curl command failed with exit code ${curl_rsp.returncode}
        ...    reproduce_hint=Run: ${curl_rsp.cmd}
        ...    details=curl command failed when trying to reach ${test_url}.\n\nCurl Response: ${curl_rsp.stdout}\nCurl Exit Code: ${curl_rsp.returncode}\nCurl Stderr: ${curl_rsp.stderr}\n\nThis indicates a connection failure, DNS resolution failure, or other network issue.\n\nCommon curl exit codes:\n- 6: Could not resolve host\n- 7: Failed to connect to host\n- 28: Operation timeout\n- 35: SSL connect error\n\nCheck network connectivity, DNS resolution, and firewall rules.
        ...    next_steps=Check Network Connectivity to `${test_url}`\nVerify DNS Resolution for the Target Host\nCheck Firewall Rules and Security Groups\nInspect ${owner_kind.stdout} `${owner_name.stdout}` Configuration
        ...    observed_at=${issue_timestamp}
    ELSE
        # Parse JSON only if curl succeeded
        TRY
            ${json}=    Evaluate    json.loads(r'''${curl_rsp.stdout}''')    json
        EXCEPT
            # JSON parsing failed - treat as connection failure
            ${issue_timestamp}=    RW.Core.Get Issue Timestamp

            RW.Core.Add Issue
            ...    severity=2
            ...    title=HTTP connection failed for ${owner_kind.stdout} `${owner_name.stdout}` - malformed response for ${test_url}
            ...    expected=Valid JSON response from curl command
            ...    actual=Failed to parse JSON from curl output
            ...    reproduce_hint=Run: ${curl_rsp.cmd}
            ...    details=curl command succeeded but returned malformed JSON response for ${test_url}.\n\nCurl Response: ${curl_rsp.stdout}\nCurl Exit Code: ${curl_rsp.returncode}\nCurl Stderr: ${curl_rsp.stderr}
            ...    next_steps=Check ${owner_kind.stdout} `${owner_name.stdout}` Status and Readiness\nVerify Service Endpoints and Load Balancer Configuration\nCheck Network Policies and Ingress Rules
            ...    observed_at=${issue_timestamp}
            RETURN
        END
        
        IF    "${json['http_code']}" == "000"
            ${issue_timestamp}=    RW.Core.Get Issue Timestamp

            RW.Core.Add Issue
            ...    severity=2
            ...    title=HTTP connection failed for ${owner_kind.stdout} `${owner_name.stdout}` - received status code 000 for ${test_url}
            ...    expected=HTTP request should complete successfully with a valid status code
            ...    actual=Received HTTP status code 000 indicating connection failure
            ...    reproduce_hint=Run: ${curl_rsp.cmd}
            ...    details=${test_url} returned HTTP status code 000, indicating a connection failure.\n\nCurl Response: ${curl_rsp.stdout}\nCurl Exit Code: ${curl_rsp.returncode}\nCurl Stderr: ${curl_rsp.stderr}\n\nThis typically means:\n- The server is unreachable\n- DNS resolution failed\n- Connection was refused\n- SSL/TLS handshake failed\n- Network timeout occurred\n\nThis is different from HTTP error codes (4xx, 5xx) as it indicates the HTTP request never completed successfully.
            ...    next_steps=Check ${owner_kind.stdout} `${owner_name.stdout}` Status and Readiness\nVerify Service Endpoints and Load Balancer Configuration\nCheck Network Policies and Ingress Rules\nInspect Pod Health and Resource Availability
            ...    observed_at=${issue_timestamp}
        ELSE IF    "${json['http_code']}" != "${DESIRED_RESPONSE_CODE}"
            ${issue_timestamp}=    RW.Core.Get Issue Timestamp

            RW.Core.Add Issue
            ...    severity=4
            ...    title=HTTP response code does not match desired response code ${DESIRED_RESPONSE_CODE} for ${owner_kind.stdout} `${owner_name.stdout}` at ${test_url}
            ...    expected=HTTP response code should be ${DESIRED_RESPONSE_CODE}
            ...    actual=Received HTTP response code ${json['http_code']}
            ...    reproduce_hint=Run: ${curl_rsp.cmd}
            ...    details=${test_url} responded with HTTP status code ${json['http_code']} instead of expected ${DESIRED_RESPONSE_CODE}.\n\nCurl Response: ${curl_rsp.stdout}\n\nCheck related ingress objects, services, and pods.
            ...    next_steps=Check ${owner_kind.stdout} Log for Issues with `${owner_name.stdout}`\n Troubleshoot Warning Events in Namespace `${owner_namespace.stdout}`\nQuery Traces for HTTP Errors in Namespace `${owner_namespace.stdout}`
            ...    observed_at=${issue_timestamp}
        END
        
        # Check latency only if connection was successful and no other issues found
        ${latency}=    Set Variable    ${json['time_total']}
        IF    "${json['http_code']}" != "000" and ${latency} > ${TARGET_LATENCY}
            ${issue_timestamp}=    RW.Core.Get Issue Timestamp

            RW.Core.Add Issue
            ...    severity=4
            ...    title=HTTP latency exceeded target latency for ${owner_kind.stdout} `${owner_name.stdout}` at ${test_url}
            ...    expected=HTTP response time should be <= ${TARGET_LATENCY} seconds
            ...    actual=HTTP response time was ${latency} seconds
            ...    reproduce_hint=Run: ${curl_rsp.cmd}
            ...    details=${test_url} responded with high latency of ${latency} seconds (target: ${TARGET_LATENCY}s).\n\nCurl Response: ${curl_rsp.stdout}\n\nCheck services, pods, load balancers, and virtual machines for unexpected saturation.
            ...    next_steps=Check ${owner_kind.stdout} Log for Issues with `${owner_name.stdout}`\nMonitor Resource Usage in Namespace `${owner_namespace.stdout}`\nCheck Load Balancer and Network Performance
            ...    observed_at=${issue_timestamp}
        END
    END
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Commands Used: ${history}
    
    # Add reporting with safe defaults for failed curl commands
    IF    ${curl_rsp.returncode} == 0
        TRY
            ${json_for_report}=    Evaluate    json.loads(r'''${curl_rsp.stdout}''')    json
            RW.Core.Add Pre To Report    URL: ${test_url}
            RW.Core.Add Pre To Report    URL Latency: ${json_for_report['time_total']}
            RW.Core.Add Pre To Report    URL Response Code: ${json_for_report['http_code']}
        EXCEPT
            RW.Core.Add Pre To Report    URL: ${test_url}
            RW.Core.Add Pre To Report    URL Latency: N/A (JSON parse failed)
            RW.Core.Add Pre To Report    URL Response Code: N/A (JSON parse failed)
        END
    ELSE
        RW.Core.Add Pre To Report    URL: ${test_url}
        RW.Core.Add Pre To Report    URL Latency: N/A (curl failed)
        RW.Core.Add Pre To Report    URL Response Code: N/A (curl failed)
    END

Suite Initialization
    ${URLS}=    RW.Core.Import User Variable    URLS
    ...    type=string
    ...    description=Comma-separated list of URLs to perform requests against.
    ...    pattern=\w*
    ...    default=https://www.runwhen.com
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
    ${OWNER_DETAILS}=    RW.Core.Import User Variable    OWNER_DETAILS
    ...    type=string
    ...    description=Json list of owner details
    ...    pattern=\w*
    ...    default={"name": "my-ingress", "kind": "Ingress", "namespace": "default"}
    ...    example={"name": "my-ingress", "kind": "Ingress", "namespace": "default"}
    Set Suite Variable    ${DESIRED_RESPONSE_CODE}    ${DESIRED_RESPONSE_CODE}
    Set Suite Variable    ${URLS}    ${URLS}
    Set Suite Variable    ${TARGET_LATENCY}    ${TARGET_LATENCY}
        ...    observed_at=${issue_timestamp}
    Set Suite Variable    ${OWNER_DETAILS}    ${OWNER_DETAILS}
