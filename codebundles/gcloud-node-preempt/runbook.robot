*** Settings ***
Metadata          Author    Shea Stewart
Documentation     List all GCP nodes that have an active preempt operation. 
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
    ${GCLOUD_SERVICE}=    RW.Core.Import Service    gcloud
    ...    type=string
    ...    description=The selected RunWhen Service to use for accessing services within a network.
    ...    pattern=\w*
    ...    example=gcloud-service.shared
    ...    default=gcloud-service.shared
    ${gcp_credentials_json}=    RW.Core.Import Secret    gcp_credentials_json
    ...    type=string
    ...    description=GCP service account json used to authenticate with GCP APIs.
    ...    pattern=\w*
    ...    example={"type": "service_account","project_id":"myproject-ID", ... super secret stuff ...}
    ${PROJECT_ID}=    RW.Core.Import User Variable    PROJECT_ID
    ...    type=string
    ...    description=The GCP Project ID to scope the API to.
    ...    pattern=\w*
    ...    example=myproject-ID
    Set Suite Variable    ${GCLOUD_SERVICE}    ${GCLOUD_SERVICE}
    Set Suite Variable    ${gcp_credentials_json}    ${gcp_credentials_json}   
    Set Suite Variable    ${env}    {"GOOGLE_APPLICATION_CREDENTIALS":"./${gcp_credentials_json.key}"}


*** Tasks ***
List all nodes in an active prempt operation
    [Documentation]    Fetches all nodes that have an active preempt operation at a global scope in the GCP Project
    [Tags]    Stdout    gcloud    node    preempt    gcp
    ${auth}=    RW.CLI.Run Cli
    ...    cmd=gcloud auth activate-service-account --key-file=./${gcp_credentials_json.key}
    ...    target_service=${GCLOUD_SERVICE}
    ...    env=${env}
    ...    secret_file__gcp_credentials_json=${gcp_credentials_json}
    ${preempt_node_list}=    RW.CLI.Run Cli
    ...    cmd=gcloud compute operations list --filter="operationType:( compute.instances.preempted ) AND NOT status:( DONE )" --format=json --project=${PROJECT_ID} | jq '[.[] | {startTime,targetLink, statusMessage, progress, zone, selfLink}]'
    ...    target_service=${GCLOUD_SERVICE}
    ...    env=${env}
    ...    secret_file__gcp_credentials_json=${gcp_credentials_json}
    ${no_requests_count}=    RW.CLI.Parse Cli Json Output
    ...    rsp=${preempt_node_list}
    ...    extract_path_to_var__preempt_node_count=length(@)
    ...    set_issue_title=Found nodes in an active preempt operation!
    ...    set_severity_level=3
    ...    preempt_node_count__raise_issue_if_gt=0
    ...    set_issue_details=Preempt operations are active on GCP nodes in this project. If services are degraded, modify the node pool or deployment replica configurations, otherwise grab a coffee or take a walk.  
    ...    assign_stdout_from_var=preempt_node_count
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Total nodes in a preempt operation: ${no_requests_count.stdout}   
    RW.Core.Add Pre To Report    Preempt operation details: \n ${preempt_node_list.stdout}
    RW.Core.Add Pre To Report    Commands Used:\n${history}