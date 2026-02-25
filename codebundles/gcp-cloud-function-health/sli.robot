*** Settings ***
Documentation       Count the number of Cloud Functions in an unhealthy state for a GCP Project.
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
Count unhealthy GCP Cloud Functions in GCP Project `${GCP_PROJECT_ID}`
    [Documentation]    Counts all GCP Functions that are not in a Healthy state
    [Tags]    gcloud    function    gcp    ${GCP_PROJECT_ID}    data:config
    ${unhealthy_cloud_function_list}=    RW.CLI.Run Cli
    ...    cmd=gcloud auth activate-service-account --key-file=$GOOGLE_APPLICATION_CREDENTIALS && gcloud functions list --filter="state!=ACTIVE OR STATUS!=ACTIVE" --format=json --project=${GCP_PROJECT_ID}
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    show_in_rwl_cheatsheet=false
    ${unhealthy_cloud_function_count}=    RW.CLI.Parse Cli Json Output
    ...    rsp=${unhealthy_cloud_function_list}
    ...    extract_path_to_var__unhealthy_function_count=length(@)
    ...    assign_stdout_from_var=unhealthy_function_count
    ${metric}=     Convert To Number    ${unhealthy_cloud_function_count.stdout}
    RW.Core.Push Metric    ${metric}    sub_name=function_health
    RW.Core.Push Metric    ${metric}

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
    ...    {"CLOUDSDK_CORE_PROJECT":"${GCP_PROJECT_ID}","GOOGLE_APPLICATION_CREDENTIALS":"./${gcp_credentials.key}","PATH":"$PATH:${OS_PATH}"}