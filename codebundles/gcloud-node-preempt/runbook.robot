*** Settings ***
Documentation       List all GCP nodes that have been preempted in the previous time interval.
Metadata            Author    stewartshea
Metadata            Display Name    GCP Node Prempt List
Metadata            Supports    GCP,GKE

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             OperatingSystem

Suite Setup         Suite Initialization


*** Tasks ***
List all nodes in an active prempt operation for GCP Project `${GCP_PROJECT_ID}`
    [Documentation]    Fetches all nodes that have been preempted within the defined time interval.
    [Tags]    stdout    gcloud    node    preempt    gcp    ${gcp_project_id}
    ${preempt_node_list}=    RW.CLI.Run Cli
    ...    cmd=gcloud auth activate-service-account --key-file=$GOOGLE_APPLICATION_CREDENTIALS && gcloud compute operations list --filter='operationType:(compute.instances.preempted)' --format=json --project=${GCP_PROJECT_ID} | jq -r --arg now "$(date -u +%s)" '[.[] | select((.startTime | sub("\\\\.[0-9]+"; "") | strptime("%Y-%m-%dT%H:%M:%S%z") | mktime) > ($now | tonumber - (${AGE}*60)))] '
    ...    env=${env}
    ...    secret_file__gcp_credentials_json=${gcp_credentials_json}
    ...    show_in_rwl_cheatsheet=true
    ...    timeout_seconds=180
    ${no_requests_count}=    RW.CLI.Parse Cli Json Output
    ...    rsp=${preempt_node_list}
    ...    extract_path_to_var__preempt_node_count=length(@)
    ...    set_issue_title=Found nodes that were preempted in the last ${AGE} minutes for Project `${GCP_PROJECT_ID}`
    ...    set_severity_level=4
    ...    preempt_node_count__raise_issue_if_gt=0
    ...    set_issue_details=Preempt operations are active on GCP nodes in this project ${GCP_PROJECT_ID}. We found $preempt_node_count nodes that preempted in the last ${AGE} minutes. If services are degraded, modify the node pool or deployment replica configurations, otherwise grab a coffee, take a walk, or call your mom.
    ...    assign_stdout_from_var=preempt_node_count
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Total nodes in a preempt operation: ${no_requests_count.stdout}
    RW.Core.Add Pre To Report    Preempt operation details: \n ${preempt_node_list.stdout}
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
    ${AGE}=    RW.Core.Import User Variable    AGE
    ...    type=string
    ...    description=The age, in minutes, since the preempt event.
    ...    pattern=\d+
    ...    default=15
    ...    example=15
    ${OS_PATH}=    Get Environment Variable    PATH
    Set Suite Variable    ${GCP_PROJECT_ID}    ${GCP_PROJECT_ID}
    Set Suite Variable    ${gcp_credentials_json}    ${gcp_credentials_json}
    Set Suite Variable    ${AGE}    ${AGE}
    Set Suite Variable
    ...    ${env}
    ...    {"CLOUDSDK_CORE_PROJECT":"${GCP_PROJECT_ID}","GOOGLE_APPLICATION_CREDENTIALS":"./${gcp_credentials_json.key}","PATH":"$PATH:${OS_PATH}"}
