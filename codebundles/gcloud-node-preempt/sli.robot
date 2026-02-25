*** Settings ***
Metadata          Author    stewartshea
Documentation     Counts nodes that have been preempted within the defined time interval.  
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
    ${AGE}=    RW.Core.Import User Variable    AGE
    ...    type=string
    ...    description=The age, in minutes, since the preempt event. 
    ...    pattern=\d+
    ...    default=30
    ...    example=30
    ${OS_PATH}=    Get Environment Variable    PATH
    Set Suite Variable    ${GCP_PROJECT_ID}    ${GCP_PROJECT_ID}
    Set Suite Variable    ${gcp_credentials}    ${gcp_credentials}
    Set Suite Variable    ${AGE}    ${AGE}
    Set Suite Variable    ${env}    {"CLOUDSDK_CORE_PROJECT":"${GCP_PROJECT_ID}","GOOGLE_APPLICATION_CREDENTIALS":"./${gcp_credentials.key}", "PATH":"$PATH:${OS_PATH}"}


*** Tasks ***
Count the number of nodes in active preempt operation in project `${GCP_PROJECT_ID}`
    [Documentation]    Counts all nodes that have been preempted within the defined time interval. 
    [Tags]    Stdout    gcloud    node    preempt    gcp    data:config
    ${preempt_node_list}=    RW.CLI.Run Cli
    ...    cmd=gcloud auth activate-service-account --key-file=$GOOGLE_APPLICATION_CREDENTIALS && gcloud compute operations list --filter='operationType:(compute.instances.preempted)' --format=json --project=${GCP_PROJECT_ID} | jq -r --arg now "$(date -u +%s)" '[.[] | select((.startTime | sub("\\\\.[0-9]+"; "") | strptime("%Y-%m-%dT%H:%M:%S%z") | mktime) > ($now | tonumber - (${AGE}*60)))] | length'
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ${metric}=     Convert To Number    ${preempt_node_list.stdout}
    RW.Core.Push Metric    ${metric}    sub_name=preemptible_nodes
    RW.Core.Push Metric    ${metric}