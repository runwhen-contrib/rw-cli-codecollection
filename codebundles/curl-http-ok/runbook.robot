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
    # Build curl command with conditional SSL verification
    ${ssl_flag}=    Set Variable If    '${VERIFY_SSL}' == 'false'    --insecure    ${EMPTY}
    ${curl_rsp}=    RW.CLI.Run Cli
    ...    cmd=curl --connect-timeout 5 --max-time 15 -L -o /dev/null -w '{"http_code": "\%{http_code}", "time_total": \%{time_total}, "time_namelookup": \%{time_namelookup}, "time_connect": \%{time_connect}, "time_appconnect": \%{time_appconnect}, "time_pretransfer": \%{time_pretransfer}, "time_starttransfer": \%{time_starttransfer}, "size_download": \%{size_download}, "speed_download": \%{speed_download}, "remote_ip": "\%{remote_ip}", "remote_port": "\%{remote_port}", "local_ip": "\%{local_ip}", "local_port": "\%{local_port}", "curl_exit_code": \%{exitcode}}' -s ${ssl_flag} ${test_url}
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
        RW.Core.Add Issue
        ...    severity=2
        ...    title=HTTP connection failed for ${owner_kind.stdout} `${owner_name.stdout}` - curl command failed for ${test_url}
        ...    expected=Curl command should succeed with exit code 0
        ...    actual=Curl command failed with exit code ${curl_rsp.returncode}
        ...    reproduce_hint=Run: ${curl_rsp.cmd}
        ...    details=curl command failed when trying to reach ${test_url}.\n\nCurl Response: ${curl_rsp.stdout}\nCurl Exit Code: ${curl_rsp.returncode}\nCurl Stderr: ${curl_rsp.stderr}\nCurl Command: ${curl_rsp.cmd}\n\nThis indicates a connection failure, DNS resolution failure, or other network issue.\n\nCommon curl exit codes:\n- 6: Could not resolve host (DNS resolution failed)\n- 7: Failed to connect to host (connection refused/unreachable)\n- 28: Operation timeout (network/server timeout)\n- 35: SSL connect error (SSL handshake failed)\n- 60: SSL certificate problem (untrusted/invalid certificate)\n- 51: SSL peer certificate or SSH remote key was not OK\n- 52: Got nothing (empty response from server)\n- 56: Failure in receiving network data\n\nFor SSL certificate issues (exit codes 35, 51, 60), consider setting VERIFY_SSL=false if using self-signed or untrusted certificates.\n\nTroubleshooting steps:\n1. Check network connectivity and DNS resolution\n2. Verify firewall rules and security groups\n3. Test with a simple curl command: curl -v ${test_url}\n4. Check if the service is running and accessible
        ...    next_steps=Check Network Connectivity to `${test_url}`\nVerify DNS Resolution for the Target Host\nCheck Firewall Rules and Security Groups\nInspect ${owner_kind.stdout} `${owner_name.stdout}` Configuration
    ELSE
        # Parse JSON only if curl succeeded
        TRY
            ${json}=    Evaluate    json.loads(r'''${curl_rsp.stdout}''')    json
        EXCEPT
            # JSON parsing failed - treat as connection failure
            RW.Core.Add Issue
            ...    severity=2
            ...    title=HTTP connection failed for ${owner_kind.stdout} `${owner_name.stdout}` - malformed response for ${test_url}
            ...    expected=Valid JSON response from curl command
            ...    actual=Failed to parse JSON from curl output
            ...    reproduce_hint=Run: ${curl_rsp.cmd}
            ...    details=curl command succeeded but returned malformed JSON response for ${test_url}.\n\nCurl Response: ${curl_rsp.stdout}\nCurl Exit Code: ${curl_rsp.returncode}\nCurl Stderr: ${curl_rsp.stderr}
            ...    next_steps=Check ${owner_kind.stdout} `${owner_name.stdout}` Status and Readiness\nVerify Service Endpoints and Load Balancer Configuration\nCheck Network Policies and Ingress Rules
            RETURN
        END
        
        IF    "${json['http_code']}" == "000"
            RW.Core.Add Issue
            ...    severity=2
            ...    title=HTTP connection failed for ${owner_kind.stdout} `${owner_name.stdout}` - received status code 000 for ${test_url}
            ...    expected=HTTP request should complete successfully with a valid status code
            ...    actual=Received HTTP status code 000 indicating connection failure
            ...    reproduce_hint=Run: ${curl_rsp.cmd}
            ...    details=${test_url} returned HTTP status code 000, indicating a connection failure.\n\nCurl Response: ${curl_rsp.stdout}\nCurl Exit Code: ${curl_rsp.returncode}\nCurl Stderr: ${curl_rsp.stderr}\n\nThis typically means:\n- The server is unreachable\n- DNS resolution failed\n- Connection was refused\n- SSL/TLS handshake failed\n- Network timeout occurred\n\nThis is different from HTTP error codes (4xx, 5xx) as it indicates the HTTP request never completed successfully.
            ...    next_steps=Check ${owner_kind.stdout} `${owner_name.stdout}` Status and Readiness\nVerify Service Endpoints and Load Balancer Configuration\nCheck Network Policies and Ingress Rules\nInspect Pod Health and Resource Availability
        ELSE
            # Check if HTTP status code is in acceptable response codes list
            ${acceptable_codes_list}=    Evaluate    [code.strip() for code in "${ACCEPTABLE_RESPONSE_CODES}".split(',')]
            ${http_code_acceptable}=    Evaluate    "${json['http_code']}" in ${acceptable_codes_list}
            IF    not ${http_code_acceptable}
                RW.Core.Add Issue
                ...    severity=4
                ...    title=HTTP response code does not match acceptable response codes ${ACCEPTABLE_RESPONSE_CODES} for ${owner_kind.stdout} `${owner_name.stdout}` at ${test_url}
                ...    expected=HTTP response code should be one of: ${ACCEPTABLE_RESPONSE_CODES}
                ...    actual=Received HTTP response code ${json['http_code']}
                ...    reproduce_hint=Run: ${curl_rsp.cmd}
                ...    details=${test_url} responded with HTTP status code ${json['http_code']} instead of acceptable codes ${ACCEPTABLE_RESPONSE_CODES}.\n\nDetailed Timing Information:\n- DNS Lookup Time: ${json.get('time_namelookup', 'N/A')}s\n- Connection Time: ${json.get('time_connect', 'N/A')}s\n- SSL Handshake Time: ${json.get('time_appconnect', 'N/A')}s\n- Time to First Byte: ${json.get('time_starttransfer', 'N/A')}s\n- Total Time: ${json.get('time_total', 'N/A')}s\n- Remote IP: ${json.get('remote_ip', 'N/A')}:${json.get('remote_port', 'N/A')}\n- Local IP: ${json.get('local_ip', 'N/A')}:${json.get('local_port', 'N/A')}\n- Download Size: ${json.get('size_download', 'N/A')} bytes\n- Download Speed: ${json.get('speed_download', 'N/A')} bytes/sec\n\nCurl Response: ${curl_rsp.stdout}\n\nHTTP Status Code Meanings:\n- 1xx: Informational responses\n- 2xx: Success responses\n- 3xx: Redirection messages\n- 4xx: Client error responses (check URL, authentication, permissions)\n- 5xx: Server error responses (check server health, resources)\n\nCheck related ingress objects, services, and pods.
                ...    next_steps=Check ${owner_kind.stdout} Log for Issues with `${owner_name.stdout}`\n Troubleshoot Warning Events in Namespace `${owner_namespace.stdout}`\nQuery Traces for HTTP Errors in Namespace `${owner_namespace.stdout}`
            END
        END
        
        # Check latency only if connection was successful and HTTP code is acceptable
        ${latency}=    Set Variable    ${json['time_total']}
        IF    "${json['http_code']}" != "000" and ${http_code_acceptable} and ${latency} > ${TARGET_LATENCY}
            RW.Core.Add Issue
            ...    severity=4
            ...    title=HTTP latency exceeded target latency for ${owner_kind.stdout} `${owner_name.stdout}` at ${test_url}
            ...    expected=HTTP response time should be <= ${TARGET_LATENCY} seconds
            ...    actual=HTTP response time was ${latency} seconds
            ...    reproduce_hint=Run: ${curl_rsp.cmd}
            ...    details=${test_url} responded with high latency of ${latency} seconds (target: ${TARGET_LATENCY}s).\n\nLatency Breakdown:\n- DNS Lookup Time: ${json.get('time_namelookup', 'N/A')}s\n- Connection Time: ${json.get('time_connect', 'N/A')}s\n- SSL Handshake Time: ${json.get('time_appconnect', 'N/A')}s\n- Pre-transfer Time: ${json.get('time_pretransfer', 'N/A')}s\n- Time to First Byte: ${json.get('time_starttransfer', 'N/A')}s\n- Total Time: ${json.get('time_total', 'N/A')}s\n\nConnection Details:\n- Remote IP: ${json.get('remote_ip', 'N/A')}:${json.get('remote_port', 'N/A')}\n- Local IP: ${json.get('local_ip', 'N/A')}:${json.get('local_port', 'N/A')}\n- Download Size: ${json.get('size_download', 'N/A')} bytes\n- Download Speed: ${json.get('speed_download', 'N/A')} bytes/sec\n\nCurl Response: ${curl_rsp.stdout}\n\nLatency Analysis:\n- If DNS lookup time is high: DNS server issues or domain resolution problems\n- If connection time is high: Network connectivity or server load issues\n- If SSL handshake time is high: SSL certificate or TLS configuration issues\n- If time to first byte is high: Server processing or backend issues\n\nCheck services, pods, load balancers, and virtual machines for unexpected saturation.
            ...    next_steps=Check ${owner_kind.stdout} Log for Issues with `${owner_name.stdout}`\nMonitor Resource Usage in Namespace `${owner_namespace.stdout}`\nCheck Load Balancer and Network Performance
        END
    END
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Commands Used: ${history}
    
    # Add reporting with safe defaults for failed curl commands
    IF    ${curl_rsp.returncode} == 0
        TRY
            ${json_for_report}=    Evaluate    json.loads(r'''${curl_rsp.stdout}''')    json
            RW.Core.Add Pre To Report    URL: ${test_url}
            RW.Core.Add Pre To Report    URL Response Code: ${json_for_report['http_code']}
            RW.Core.Add Pre To Report    URL Total Latency: ${json_for_report['time_total']}s
            RW.Core.Add Pre To Report    URL DNS Lookup Time: ${json_for_report.get('time_namelookup', 'N/A')}s
            RW.Core.Add Pre To Report    URL Connection Time: ${json_for_report.get('time_connect', 'N/A')}s
            RW.Core.Add Pre To Report    URL SSL Handshake Time: ${json_for_report.get('time_appconnect', 'N/A')}s
            RW.Core.Add Pre To Report    URL Time to First Byte: ${json_for_report.get('time_starttransfer', 'N/A')}s
            RW.Core.Add Pre To Report    URL Remote IP: ${json_for_report.get('remote_ip', 'N/A')}:${json_for_report.get('remote_port', 'N/A')}
            RW.Core.Add Pre To Report    URL Download Size: ${json_for_report.get('size_download', 'N/A')} bytes
            RW.Core.Add Pre To Report    URL Download Speed: ${json_for_report.get('speed_download', 'N/A')} bytes/sec
            RW.Core.Add Pre To Report    SSL Verification: ${VERIFY_SSL}
        EXCEPT
            RW.Core.Add Pre To Report    URL: ${test_url}
            RW.Core.Add Pre To Report    URL Latency: N/A (JSON parse failed)
            RW.Core.Add Pre To Report    URL Response Code: N/A (JSON parse failed)
            RW.Core.Add Pre To Report    SSL Verification: ${VERIFY_SSL}
        END
    ELSE
        RW.Core.Add Pre To Report    URL: ${test_url}
        RW.Core.Add Pre To Report    URL Latency: N/A (curl failed)
        RW.Core.Add Pre To Report    URL Response Code: N/A (curl failed)
        RW.Core.Add Pre To Report    Curl Exit Code: ${curl_rsp.returncode}
        RW.Core.Add Pre To Report    SSL Verification: ${VERIFY_SSL}
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
    ${ACCEPTABLE_RESPONSE_CODES}=    RW.Core.Import User Variable    ACCEPTABLE_RESPONSE_CODES
    ...    type=string
    ...    description=Comma-separated list of HTTP response codes that indicate success and connectivity (e.g., 200,201,202,204,301,302,307,401,403).
    ...    pattern=\w*
    ...    default=200,201,202,204,301,302,307,401,403
    ...    example=200,201,202,204,301,302,307,401,403
    ${OWNER_DETAILS}=    RW.Core.Import User Variable    OWNER_DETAILS
    ...    type=string
    ...    description=Json list of owner details
    ...    pattern=\w*
    ...    default={"name": "my-ingress", "kind": "Ingress", "namespace": "default"}
    ...    example={"name": "my-ingress", "kind": "Ingress", "namespace": "default"}
    ${VERIFY_SSL}=    RW.Core.Import User Variable    VERIFY_SSL
    ...    type=string
    ...    description=Whether to verify SSL certificates. Set to 'false' to ignore SSL certificate errors.
    ...    pattern=\w*
    ...    default=false
    ...    example=true
    Set Suite Variable    ${ACCEPTABLE_RESPONSE_CODES}    ${ACCEPTABLE_RESPONSE_CODES}
    Set Suite Variable    ${URLS}    ${URLS}
    Set Suite Variable    ${TARGET_LATENCY}    ${TARGET_LATENCY}
    Set Suite Variable    ${OWNER_DETAILS}    ${OWNER_DETAILS}
    Set Suite Variable    ${VERIFY_SSL}    ${VERIFY_SSL}
