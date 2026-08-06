*** Settings ***
Documentation       Scores GCP Cloud Function health as a binary value: 1 only if every health dimension passes (no unhealthy functions, no public invokers, no failed builds, gen2 Cloud Run services ready), 0 if any dimension is degraded.
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
Score Unhealthy Cloud Functions in GCP Project `${GCP_PROJECT_ID}`
    [Documentation]    Scores 1 if no Cloud Functions (gen1 or gen2) are in a non-ACTIVE state, 0 otherwise.
    [Tags]    gcloud    function    gcp    ${GCP_PROJECT_ID}    data:config
    ${unhealthy_cloud_function_list}=    RW.CLI.Run Cli
    ...    cmd=gcloud functions list --filter="state!=ACTIVE OR status!=ACTIVE" --format=json --project=${GCP_PROJECT_ID}
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    show_in_rwl_cheatsheet=false
    ${unhealthy_cloud_function_count}=    RW.CLI.Parse Cli Json Output
    ...    rsp=${unhealthy_cloud_function_list}
    ...    extract_path_to_var__unhealthy_function_count=length(@)
    ...    assign_stdout_from_var=unhealthy_function_count
    ${function_state_score}=    Evaluate    1 if int(${unhealthy_cloud_function_count.stdout}) == 0 else 0
    Set Suite Variable    ${function_state_score}
    RW.Core.Push Metric    ${unhealthy_cloud_function_count.stdout}    sub_name=unhealthy_function_count
    RW.Core.Push Metric    ${function_state_score}    sub_name=function_state

Score Cloud Function IAM Configuration in GCP Project `${GCP_PROJECT_ID}`
    [Documentation]    Scores 1 if no Cloud Function grants invoker access to allUsers or allAuthenticatedUsers, 0 otherwise.
    [Tags]    gcloud    function    gcp    ${GCP_PROJECT_ID}    security    data:config
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check_function_iam.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ${issues_output}=    RW.CLI.Run Cli
    ...    cmd=cat function_iam_issues.json | jq length
    ...    env=${env}
    ${iam_score}=    Evaluate    1 if int(${issues_output.stdout}) == 0 else 0
    Set Suite Variable    ${iam_score}
    RW.Core.Push Metric    ${issues_output.stdout}    sub_name=public_invoker_count
    RW.Core.Push Metric    ${iam_score}    sub_name=iam_config

Score Cloud Function Build Health in GCP Project `${GCP_PROJECT_ID}`
    [Documentation]    Scores 1 if no failed function deployments or failed Cloud Build jobs exist, 0 otherwise.
    [Tags]    gcloud    function    cloudbuild    gcp    ${GCP_PROJECT_ID}    data:config
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check_function_builds.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ${issues_output}=    RW.CLI.Run Cli
    ...    cmd=cat function_build_issues.json | jq length
    ...    env=${env}
    ${build_score}=    Evaluate    1 if int(${issues_output.stdout}) == 0 else 0
    Set Suite Variable    ${build_score}
    RW.Core.Push Metric    ${issues_output.stdout}    sub_name=failed_build_count
    RW.Core.Push Metric    ${build_score}    sub_name=build_health

Score Gen2 Cloud Run Service Health in GCP Project `${GCP_PROJECT_ID}`
    [Documentation]    Scores 1 if all gen2 function Cloud Run services are Ready with traffic on their latest revision, 0 otherwise.
    [Tags]    gcloud    function    cloudrun    gcp    ${GCP_PROJECT_ID}    data:config
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check_gen2_run_health.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ${issues_output}=    RW.CLI.Run Cli
    ...    cmd=cat gen2_run_health_issues.json | jq length
    ...    env=${env}
    ${gen2_run_score}=    Evaluate    1 if int(${issues_output.stdout}) == 0 else 0
    Set Suite Variable    ${gen2_run_score}
    RW.Core.Push Metric    ${issues_output.stdout}    sub_name=gen2_unhealthy_service_count
    RW.Core.Push Metric    ${gen2_run_score}    sub_name=gen2_run_health

Generate Aggregate Cloud Function Health Score for `${GCP_PROJECT_ID}`
    [Documentation]    Overall score is 1 only if every health dimension passes; 0 if any dimension is degraded.
    [Tags]    gcloud    function    gcp    ${GCP_PROJECT_ID}    data:metrics
    ${health_score}=    Evaluate    1 if (${function_state_score} + ${iam_score} + ${build_score} + ${gen2_run_score}) == 4 else 0
    RW.Core.Add to Report    Cloud Function Health Score: ${health_score} -- function_state: ${function_state_score}, iam: ${iam_score}, builds: ${build_score}, gen2_run: ${gen2_run_score}
    RW.Core.Push Metric    ${health_score}

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
    ...    {"CLOUDSDK_CORE_PROJECT":"${GCP_PROJECT_ID}","PATH":"$PATH:${OS_PATH}"}
    RW.CLI.Run CLI
    ...    cmd=gcloud auth activate-service-account --key-file="./${gcp_credentials.key}" || true
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
