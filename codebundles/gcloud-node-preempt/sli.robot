*** Settings ***
Metadata          Author    stewartshea
Documentation     Check if any GCP nodes have an active preempt operation. 
Metadata          Display Name    GCP Node Prempt List 
Metadata          Supports    GCP,GKE
Suite Setup       Suite Initialization
Library           BuiltIn
Library           RW.Core
Library           RW.CLI
Library           RW.platform
Library           OperatingSystem

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
    Set Suite Variable    ${gcp_credentials_json}    ${gcp_credentials_json}   
    Set Suite Variable    ${env}    {"CLOUDSDK_CORE_PROJECT":"${GCP_PROJECT_ID}","GOOGLE_APPLICATION_CREDENTIALS":"./${gcp_credentials_json.key}"}


*** Tasks ***
Count the number of nodes in active prempt operation
    [Documentation]    Fetches all nodes that have an active preempt operation at a global scope in the GCP Project
    [Tags]    Stdout    gcloud    node    preempt    gcp
    ${preempt_node_list}=    RW.CLI.Run Cli
    ...    cmd=gcloud auth activate-service-account --key-file=$GOOGLE_APPLICATION_CREDENTIALS && gcloud compute operations list --filter="operationType:(compute.instances.preempted) AND progress<100" --format=json --project=${GCP_PROJECT_ID}
    ...    env=${env}
    ...    secret_file__gcp_credentials_json=${gcp_credentials_json}
    ${no_requests_count}=    RW.CLI.Parse Cli Json Output
    ...    rsp=${preempt_node_list}
    ...    extract_path_to_var__preempt_node_count=length(@)
    ...    assign_stdout_from_var=preempt_node_count
    ${metric}=     Convert To Number    ${no_requests_count.stdout}
    RW.Core.Push Metric    ${metric}