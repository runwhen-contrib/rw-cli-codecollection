*** Settings ***
Documentation       Identify problems related to GCP Cloud Function deployments (gen1 and gen2)
Metadata            Author    stewartshea
Metadata            Display Name    GCP Cloud Function Health
Metadata            Supports    GCP,Cloud Functions

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             OperatingSystem
Library             Collections
Library             DateTime

Suite Setup         Suite Initialization

*** Tasks ***
List Unhealthy Cloud Functions in GCP Project `${GCP_PROJECT_ID}`
    [Documentation]    Fetches a list of GCP Cloud Functions (gen1 and gen2) that are not healthy.
    [Tags]    gcloud    function    gcp    ${GCP_PROJECT_ID}    access:read-only    data:config
    # This command is cheat-sheet friendly
    ${unhealthy_cloud_function_list_simple_output}=    RW.CLI.Run Cli
    ...    cmd=gcloud functions list --filter="state!=ACTIVE OR status!=ACTIVE" --format="table[box](name, environment, state, status, stateMessages.severity, stateMessages.type, stateMessages.message:wrap=30)" --project=${GCP_PROJECT_ID} && echo "Run 'gcloud functions describe [name]' for full details."
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    show_in_rwl_cheatsheet=true

    # Generate JSON List for additional processing
    ${unhealthy_cloud_function_list}=    RW.CLI.Run Cli
    ...    cmd=gcloud functions list --filter="state!=ACTIVE OR status!=ACTIVE" --format=json --project=${GCP_PROJECT_ID}
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
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
            ${environment}=    Set Variable If    'environment' in $item    $item['environment']    'GEN_1'
            ${observed_at}=    Set Variable    ${item["updateTime"]}
            IF    'GEN_2' in $environment
                ${state_messages}=    Evaluate    $item.get('stateMessages', [])
                ${has_messages}=    Evaluate    len($state_messages) > 0
                IF    ${has_messages}
                    ${msg_type}=    Evaluate    $state_messages[0].get('type', 'Unknown error')
                    ${item_next_steps}=    RW.CLI.Run Bash File
                    ...    bash_file=cloud_functions_next_steps.sh
                    ...    cmd_override=./cloud_functions_next_steps.sh "${msg_type}" "${GCP_PROJECT_ID}"
                    ...    env=${env}
                    ...    include_in_history=False
                ELSE
                    ${item_next_steps}=    RW.CLI.Run Bash File
                    ...    bash_file=cloud_functions_next_steps.sh
                    ...    cmd_override=./cloud_functions_next_steps.sh "Unknown version or error. No message provided." "${GCP_PROJECT_ID}"
                    ...    env=${env}
                    ...    include_in_history=False
                END
            ELSE
                ${item_next_steps}=    RW.CLI.Run Bash File
                ...    bash_file=cloud_functions_next_steps.sh
                ...    cmd_override=./cloud_functions_next_steps.sh "Unknown version or error. No message provided." "${GCP_PROJECT_ID}"
                ...    env=${env}
                ...    include_in_history=False
            END
            RW.Core.Add Issue
            ...    severity=1
            ...    expected=GCP Cloud Functions should be in a healthy state in GCP Project `${GCP_PROJECT_ID}`.
            ...    actual=Cloud Function `${name.stdout}` in GCP Project `${GCP_PROJECT_ID}` is in an unhealthy state.
            ...    title=Cloud Function `${name.stdout}` in GCP Project `${GCP_PROJECT_ID}` is unhealthy.
            ...    reproduce_hint=${unhealthy_cloud_function_list_simple_output.cmd}
            ...    details=Cloud Function `${name.stdout}` (${environment}) in location `${location.stdout}` in GCP Project `${GCP_PROJECT_ID}` is unhealthy with the following details:\n${item}
            ...    next_steps=${item_next_steps.stdout}
            ...    observed_at=${observed_at}
        END
    END
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Failed GCP Functions Table:\n${unhealthy_cloud_function_list_simple_output.stdout}
    RW.Core.Add Pre To Report    Commands Used:\n${history}

Get Error Logs for Unhealthy Cloud Functions in GCP Project `${GCP_PROJECT_ID}`
   [Documentation]    Fetches GCP logs related to unhealthy Cloud Functions within the last 14 days. Gen1 functions log under resource.type=cloud_function; gen2 functions log under resource.type=cloud_run_revision.
    [Tags]    gcloud    function    gcp    ${GCP_PROJECT_ID}    access:read-only    data:logs-regexp
    # This command is cheat-sheet friendly
    ${error_logs_simple_output}=    RW.CLI.Run Cli
    ...    cmd=gcloud functions list --filter="state!=ACTIVE OR status!=ACTIVE" --format="value(name)" --project=${GCP_PROJECT_ID} | xargs -I {} gcloud logging read "severity=ERROR AND (resource.type=cloud_function AND resource.labels.function_name={} OR resource.type=cloud_run_revision AND resource.labels.service_name={})" --limit 50 --freshness=14d
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    show_in_rwl_cheatsheet=true

    # Generate list of unhealthy items for further processing
    ${unhealthy_cloud_function_list}=    RW.CLI.Run Cli
    ...    cmd=gcloud functions list --filter="state!=ACTIVE OR status!=ACTIVE" --format=json --project=${GCP_PROJECT_ID}
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    show_in_rwl_cheatsheet=false
    ${unhealthy_cloud_function_json}=    Evaluate    json.loads(r'''${unhealthy_cloud_function_list.stdout}''')    json
    ${timestamp}=    DateTime.Get Current Date
    IF    len(@{unhealthy_cloud_function_json}) > 0
        FOR    ${item}    IN    @{unhealthy_cloud_function_json}
            ${location}=    RW.CLI.Run Cli
            ...    cmd=echo "${item["name"]}" | awk -F'/' '{print $4}' | tr -d '\n'| sed 's/\"//g'
            ...    include_in_history=False
            ${name}=    RW.CLI.Run Cli
            ...    cmd=echo "${item["name"]}" | awk -F'/' '{print $6}' | tr -d '\n'| sed 's/\"//g'
            ...    include_in_history=False
            ${item_error_logs_output}=    RW.CLI.Run Cli
            ...    cmd=gcloud logging read "severity=ERROR AND (resource.type=cloud_function AND resource.labels.function_name=${name.stdout} OR resource.type=cloud_run_revision AND resource.labels.service_name=${name.stdout})" --limit 50 --freshness=14d --format="json"
            ...    env=${env}
            ...    secret_file__gcp_credentials=${gcp_credentials}
            ...    show_in_rwl_cheatsheet=false
            ${error_logs_json}=    Evaluate    json.loads(r'''${item_error_logs_output.stdout}''')    json
            IF    len(@{error_logs_json}) > 0

                # Create a newline list of errors
                ${error_message_list}=    Set Variable    ${EMPTY}
                FOR    ${log}    IN    @{error_logs_json}
                    ${message_contents}=    Evaluate    $log.get('protoPayload', {}).get('status', {}).get('message', '') or $log.get('textPayload', '') or str($log.get('jsonPayload', ''))
                    ${error_message_list}=    Catenate    SEPARATOR=\n    ${error_message_list}    ${message_contents}
                END

                # Send list of messages to next_steps script for recommendations
                ${item_next_steps}=    RW.CLI.Run Bash File
                ...    bash_file=cloud_functions_next_steps.sh
                ...    cmd_override=./cloud_functions_next_steps.sh "${error_message_list}" "${GCP_PROJECT_ID}"
                ...    env=${env}
                ...    include_in_history=False

                ${first_timestamp}=    Set Variable    ${error_logs_json[0].get("timestamp", "${timestamp}")}

                # Create a new issue specific to this one function with all recommended next steps and log details
                RW.Core.Add Issue
                ...    severity=3
                ...    expected=Cloud Function `${name.stdout}` should have no error logs in GCP Project `${GCP_PROJECT_ID}`.
                ...    actual=Cloud Function `${name.stdout}` in GCP Project `${GCP_PROJECT_ID}` has error logs.
                ...    title=Cloud Function `${name.stdout}` in GCP Project `${GCP_PROJECT_ID}` has error logs.
                ...    reproduce_hint=${item_error_logs_output.cmd}
                ...    details=Cloud Function `${name.stdout}` in location `${location.stdout}` in GCP Project `${GCP_PROJECT_ID}` has the following error logs:\n${error_logs_json}
                ...    next_steps=${item_next_steps.stdout}
                ...    observed_at=${first_timestamp}
            END
        END
    END
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    GCP Cloud Function Error Logs:\n${error_logs_simple_output.stdout}
    RW.Core.Add Pre To Report    Commands Used:\n${history}

Fetch Cloud Function Configurations in GCP Project `${GCP_PROJECT_ID}`
    [Documentation]    Fetches full configuration details (runtime, memory, timeout, service account, ingress, VPC) for all Cloud Functions (gen1 and gen2), flagging functions without dedicated service accounts.
    [Tags]    gcloud    function    gcp    ${GCP_PROJECT_ID}    access:read-only    data:config
    ${config_result}=    RW.CLI.Run Bash File
    ...    bash_file=fetch_function_config.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    show_in_rwl_cheatsheet=true
    ...    timeout_seconds=180
    ...    cmd_override=./fetch_function_config.sh
    ${config_issues}=    RW.CLI.Run Cli
    ...    cmd=cat function_config_issues.json
    ...    env=${env}
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${config_issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for function config, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=${issue['expected']}
            ...    actual=${issue['actual']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${config_result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    Cloud Function Configurations:\n${config_result.stdout}

Check Cloud Function IAM Policies in GCP Project `${GCP_PROJECT_ID}`
    [Documentation]    Checks IAM policies on all Cloud Functions (gen1 and gen2) for public invoker access (allUsers or allAuthenticatedUsers).
    [Tags]    gcloud    function    gcp    ${GCP_PROJECT_ID}    security    access:read-only    data:config
    ${iam_result}=    RW.CLI.Run Bash File
    ...    bash_file=check_function_iam.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    show_in_rwl_cheatsheet=true
    ...    timeout_seconds=180
    ...    cmd_override=./check_function_iam.sh
    ${iam_issues}=    RW.CLI.Run Cli
    ...    cmd=cat function_iam_issues.json
    ...    env=${env}
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${iam_issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for function IAM, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=${issue['expected']}
            ...    actual=${issue['actual']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${iam_result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    Cloud Function IAM Analysis:\n${iam_result.stdout}

Check Gen2 Cloud Run Service Health in GCP Project `${GCP_PROJECT_ID}`
    [Documentation]    Checks the underlying Cloud Run services for gen2 Cloud Functions -- Ready conditions, revision health, and traffic routing.
    [Tags]    gcloud    function    cloudrun    gcp    ${GCP_PROJECT_ID}    access:read-only    data:config
    ${run_result}=    RW.CLI.Run Bash File
    ...    bash_file=check_gen2_run_health.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    show_in_rwl_cheatsheet=true
    ...    timeout_seconds=180
    ...    cmd_override=./check_gen2_run_health.sh
    ${run_issues}=    RW.CLI.Run Cli
    ...    cmd=cat gen2_run_health_issues.json
    ...    env=${env}
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${run_issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for gen2 run health, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=${issue['expected']}
            ...    actual=${issue['actual']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${run_result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    Gen2 Cloud Run Health:\n${run_result.stdout}

Check for Failed Cloud Function Builds in GCP Project `${GCP_PROJECT_ID}`
    [Documentation]    Detects failed Cloud Function deployments (state messages) and failed Cloud Build jobs (gen2 builds).
    [Tags]    gcloud    function    cloudbuild    gcp    ${GCP_PROJECT_ID}    access:read-only    data:config
    ${build_result}=    RW.CLI.Run Bash File
    ...    bash_file=check_function_builds.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    show_in_rwl_cheatsheet=true
    ...    timeout_seconds=180
    ...    cmd_override=./check_function_builds.sh
    ${build_issues}=    RW.CLI.Run Cli
    ...    cmd=cat function_build_issues.json
    ...    env=${env}
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${build_issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for function builds, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=${issue['expected']}
            ...    actual=${issue['actual']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${build_result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    Cloud Function Build Analysis:\n${build_result.stdout}

Check Cloud Function Scaling and Timeout Configuration in GCP Project `${GCP_PROJECT_ID}`
    [Documentation]    Flags HTTP functions with long timeouts and gen2 functions without a max instance cap (unbounded scaling cost risk).
    [Tags]    gcloud    function    gcp    ${GCP_PROJECT_ID}    access:read-only    data:config
    ${scaling_result}=    RW.CLI.Run Bash File
    ...    bash_file=check_function_scaling.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    show_in_rwl_cheatsheet=true
    ...    timeout_seconds=180
    ...    cmd_override=./check_function_scaling.sh
    ${scaling_issues}=    RW.CLI.Run Cli
    ...    cmd=cat function_scaling_issues.json
    ...    env=${env}
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${scaling_issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for function scaling, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=${issue['expected']}
            ...    actual=${issue['actual']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${scaling_result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    Cloud Function Scaling Analysis:\n${scaling_result.stdout}

*** Keywords ***
Suite Initialization
    ${gcp_credentials}=    RW.Core.Import Secret    gcp_credentials
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
    Set Suite Variable    ${gcp_credentials}    ${gcp_credentials}
    Set Suite Variable
    ...    ${env}
    ...    {"CLOUDSDK_CORE_PROJECT":"${GCP_PROJECT_ID}","PATH":"$PATH:${OS_PATH}", "GCP_PROJECT_ID":"${GCP_PROJECT_ID}"}
    RW.CLI.Run CLI
    ...    cmd=gcloud auth activate-service-account --key-file="./${gcp_credentials.key}" || true
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
