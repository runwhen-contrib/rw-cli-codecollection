*** Settings ***
Documentation       Identify problems related to GCP Cloud Function deployments
Metadata            Author    stewartshea
Metadata            Display Name    GCP Cloud Function Health
Metadata            Supports    GCP

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             OperatingSystem

Suite Setup         Suite Initialization

*** Tasks ***
List failed Cloud Functions in GCP Project `${GCP_PROJECT_ID}`
    [Documentation]    Fetches a list of GCP Cloud Functions that are not healthy.
    [Tags]    gcloud    function    gcp    ${GCP_PROJECT_ID}
    # This command is cheat-sheet friendly
    ${unhealthy_cloud_function_list_simple_output}=    RW.CLI.Run Cli
    ...    cmd=gcloud auth activate-service-account --key-file=$GOOGLE_APPLICATION_CREDENTIALS && gcloud functions list --filter="state:(FAILED)" --format="table[box](name, state, stateMessages.severity, stateMessages.type, stateMessages.message:wrap=30)" --project=${GCP_PROJECT_ID} && echo "Run 'gcloud functions describe [name]' for full details."
    ...    env=${env}
    ...    secret_file__gcp_credentials_json=${gcp_credentials_json}
    ...    show_in_rwl_cheatsheet=true

    # Generate JSON List for additional processing
    ${unhealthy_cloud_function_list}=    RW.CLI.Run Cli
    ...    cmd=gcloud auth activate-service-account --key-file=$GOOGLE_APPLICATION_CREDENTIALS && gcloud functions list --filter="state:(FAILED)" --format=json --project=${GCP_PROJECT_ID}
    ...    env=${env}
    ...    secret_file__gcp_credentials_json=${gcp_credentials_json}
    ...    show_in_rwl_cheatsheet=false
    ${cloud_function_json}=    Evaluate    json.loads(r'''${unhealthy_cloud_function_list.stdout}''')    json
    IF    len(@{cloud_function_json}) > 0
        FOR    ${item}    IN    @{cloud_function_json}   
            ${location}=    RW.CLI.Run Cli
            ...    cmd=echo "${item["name"]}" | awk -F'/' '{print $4}' | tr -d '\n'| sed 's/\"//g'
            ...    include_in_history=False
            ${name}=    RW.CLI.Run Cli
            ...    cmd=echo "${item["name"]}" | awk -F'/' '{print $6}' | tr -d '\n'| sed 's/\"//g'
            ...    include_in_history=False
            ${item_next_steps}=    RW.CLI.Run Bash File
            ...    bash_file=cloud_functions_next_steps.sh
            ...    cmd_override=./cloud_functions_next_steps.sh "${item["stateMessages"][0]["type"]}" "${GCP_PROJECT_ID}"
            ...    env=${env}
            ...    include_in_history=False
            RW.Core.Add Issue
            ...    severity=1
            ...    expected=GCP Cloud Functions should be in a healthy state in GCP Project `${GCP_PROJECT_ID}`.
            ...    actual=Cloud Function `${name.stdout}` in GCP Project `${GCP_PROJECT_ID}` is in an unhealthy state.
            ...    title=Cloud Function `${name.stdout}` in GCP Project `${GCP_PROJECT_ID}` is unhealthy.
            ...    reproduce_hint=View Commands Used in Report Output
            ...    details=Cloud Function `${name.stdout}` in location `${location.stdout}` in GCP Project `${GCP_PROJECT_ID}` is unhealthy with the following details:\n${item}
            ...    next_steps=${item_next_steps.stdout}
        END
    END
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Failed GCP Functions Table:\n${unhealthy_cloud_function_list_simple_output.stdout}
    RW.Core.Add Pre To Report    Commands Used:\n${history}

Get Error Logs for Failed Cloud Functions in GCP Project `${GCP_PROJECT_ID}`
   [Documentation]    Fetches GCP logs related to failed Cloud Functions within the last 14 days
    [Tags]    gcloud    function    gcp    ${GCP_PROJECT_ID}
    # This command is cheat-sheet friendly
    ${error_logs_simple_output}=    RW.CLI.Run Cli
    ...    cmd=gcloud functions list --filter="state:(FAILED)" --format="value(name)" --project=${GCP_PROJECT_ID} | xargs -I {} gcloud logging read "severity=ERROR AND resource.type=cloud_function AND resource.labels.function_name={}" --limit 50 --freshness=14d
    ...    env=${env}
    ...    secret_file__gcp_credentials_json=${gcp_credentials_json}
    ...    show_in_rwl_cheatsheet=true

    # Generate JSON List for additional processing    
    ${error_logs_list}=    RW.CLI.Run Cli
    ...    cmd=gcloud functions list --filter="state:(FAILED)" --format="value(name)" --project=${GCP_PROJECT_ID} | xargs -I {} gcloud logging read "severity=ERROR AND resource.type=cloud_function AND resource.labels.function_name={}" --limit 50 --freshness=14d --format="json"
    ...    env=${env}
    ...    secret_file__gcp_credentials_json=${gcp_credentials_json}
    ...    show_in_rwl_cheatsheet=false
    ${error_logs_json}=    Evaluate    json.loads(r'''${error_logs_list.stdout}''')    json
    IF    len(@{error_logs_json}) > 0
        FOR    ${item}    IN    @{error_logs_json}   
            ${location}=    RW.CLI.Run Cli
            ...    cmd=echo "${item["protoPayload"]["resourceName"]}" | awk -F'/' '{print $4}' | tr -d '\n'| sed 's/\"//g'
            ...    include_in_history=False
            ${name}=    RW.CLI.Run Cli
            ...    cmd=echo "${item["protoPayload"]["resourceName"]}" | awk -F'/' '{print $6}' | tr -d '\n'| sed 's/\"//g'
            ...    include_in_history=False
            ${item_next_steps}=    RW.CLI.Run Bash File
            ...    bash_file=cloud_functions_next_steps.sh
            ...    cmd_override=./cloud_functions_next_steps.sh "${item["protoPayload"]["status"]["message"]}" "${GCP_PROJECT_ID}"
            ...    env=${env}
            ...    include_in_history=False
            RW.Core.Add Issue
            ...    severity=3
            ...    expected=Cloud Function `${name.stdout}` should have no error logs in GCP Project `${GCP_PROJECT_ID}`.
            ...    actual=Cloud Function `${name.stdout}` in GCP Project `${GCP_PROJECT_ID}` has error logs.
            ...    title=Cloud Function `${name.stdout}` in GCP Project `${GCP_PROJECT_ID}` has error logs.
            ...    reproduce_hint=View Commands Used in Report Output
            ...    details=Cloud Function `${name.stdout}` in location `${location.stdout}` in GCP Project `${GCP_PROJECT_ID}` has the following error log:\n${item}
            ...    next_steps=${item_next_steps.stdout}
        END
    END
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    GCP Cloud Function Error Logs:\n${error_logs_simple_output.stdout}
    RW.Core.Add Pre To Report    Commands Used:\n${history}

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
    ...    {"CLOUDSDK_CORE_PROJECT":"${GCP_PROJECT_ID}","GOOGLE_APPLICATION_CREDENTIALS":"./${gcp_credentials_json.key}","PATH":"$PATH:${OS_PATH}", "GCP_PROJECT_ID":"${GCP_PROJECT_ID}"}