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
Check HTTP URL Availability and Timeliness for `${URL}`
    [Documentation]    Use cURL to validate the http response
    [Tags]    curl    http    ingress    latency    errors    access:read-only
    ${curl_rsp}=    RW.CLI.Run Cli
    ...    cmd=curl --connect-timeout 5 --max-time 15 -o /dev/null -w '{"http_code": \%{http_code}, "time_total": \%{time_total}}' -s ${URL}
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
    ${http_rsp_code}=    RW.CLI.Parse Cli Json Output
    ...    rsp=${curl_rsp}
    ...    extract_path_to_var__http_code=http_code
    ...    set_issue_title=Actual HTTP response code $http_code does not match desired HTTP response code ${DESIRED_RESPONSE_CODE} for ${owner_kind.stdout} `${owner_name.stdout}`
    ...    set_severity_level=4
    ...    http_code__raise_issue_if_neq=${DESIRED_RESPONSE_CODE}
    ...    set_issue_details=${URL} responded with a status of:$http_code \n\n Check related ingress objects, services, and pods.
    ...    set_issue_next_steps=Check ${owner_kind.stdout} Log for Issues with `${owner_name.stdout}`\n Troubleshoot Warning Events in Namespace `${owner_namespace.stdout}`\nQuery Traces for HTTP Errors in Namespace `${owner_namespace.stdout}`
    ...    assign_stdout_from_var=http_code
    ${http_latency}=    RW.CLI.Parse Cli Json Output
    ...    rsp=${curl_rsp}
    ...    extract_path_to_var__time_total=time_total
    ...    set_issue_title=Actual HTTP latency exceeded target latency for ${owner_kind.stdout} `${owner_name.stdout}`
    ...    set_severity_level=4
    ...    time_total__raise_issue_if_gt=${TARGET_LATENCY}
    ...    set_issue_next_steps=Check ${owner_kind.stdout} Log for Issues with `${owner_name.stdout}`
    ...    set_issue_details=${URL} responded with a latency of $time_total. Check services, pods, load balanacers, and virtual machines for unexpected saturation.
    ...    assign_stdout_from_var=time_total
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Commands Used: ${history}
    RW.Core.Add Pre To Report    URL Latency: ${http_latency.stdout}
    RW.Core.Add Pre To Report    URL Response Code: ${http_rsp_code.stdout}


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
    ${OWNER_DETAILS}=    RW.Core.Import User Variable    OWNER_DETAILS
    ...    type=string
    ...    description=Json list of owner details
    ...    pattern=\w*
    ...    default={"name": "my-ingress", "kind": "Ingress", "namespace": "default"}
    ...    example={"name": "my-ingress", "kind": "Ingress", "namespace": "default"}
    Set Suite Variable    ${DESIRED_RESPONSE_CODE}    ${DESIRED_RESPONSE_CODE}
    Set Suite Variable    ${URL}    ${URL}
    Set Suite Variable    ${TARGET_LATENCY}    ${TARGET_LATENCY}
    Set Suite Variable    ${OWNER_DETAILS}    ${OWNER_DETAILS}
