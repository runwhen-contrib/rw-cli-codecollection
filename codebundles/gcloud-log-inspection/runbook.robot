*** Settings ***
Metadata          Author    jon-funk
Metadata          Display Name    GCP Gcloud Log Inspection
Metadata          Supports    GCP,Gcloud,Google Monitoring
Documentation     Fetches logs from a GCP using a configurable query and raises an issue with details on the most common issues.
Suite Setup       Suite Initialization
Library           RW.Core
Library           RW.CLI
Library           OperatingSystem

*** Keywords ***
Suite Initialization
    ${SEVERITY}=    RW.Core.Import User Variable    SEVERITY
    ...    type=string
    ...    description=What minimum severity to filter for. See https://cloud.google.com/logging/docs/reference/v2/rest/v2/LogEntry#LogSeverity for examples.
    ...    pattern=\w*
    ...    enum=[EMERGENCY,ALERT,CRITICAL,ERROR,WARNING,NOTICE,INFO,DEBUG,DEFAULT]
    ...    default=ERROR
    ...    example=ERROR
    ${ADD_FILTERS}=    RW.Core.Import User Variable    ADD_FILTERS
    ...    type=string
    ...    description=Extra optional filters to add to the gcloud log read request. See https://cloud.google.com/logging/docs/view/logging-query-language for syntax.
    ...    pattern=\w*
    ...    default=
    ...    example=resource.labels.cluster_name=mycluster-1
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
    ${GCP_PROJECT_ID}=    RW.Core.Import User Variable    GCP_PROJECT_ID
    ...    type=string
    ...    description=The GCP Project ID to scope the API to.
    ...    pattern=\w*
    ...    example=myproject-ID
    ${OS_PATH}=    Get Environment Variable    PATH
    Set Suite Variable    ${SEVERITY}    ${SEVERITY}
    Set Suite Variable    ${GCLOUD_SERVICE}    ${GCLOUD_SERVICE}
    Set Suite Variable    ${gcp_credentials_json}    ${gcp_credentials_json}
    Set Suite Variable    ${GCP_PROJECT_ID}    ${GCP_PROJECT_ID}
    IF    "${ADD_FILTERS}" != ""
        ${ADD_FILTERS}=    Set Variable    \ AND ${ADD_FILTERS}        
    END
    Set Suite Variable    ${ADD_FILTERS}    ${ADD_FILTERS}
    Set Suite Variable    ${env}    {"CLOUDSDK_CORE_PROJECT":"${GCP_PROJECT_ID}","GOOGLE_APPLICATION_CREDENTIALS":"./${gcp_credentials_json.key}","PATH":"$PATH:${OS_PATH}"}

*** Tasks ***
Inspect GCP Logs For Common Errors in GCP Project `${GCP_PROJECT_ID}`
    [Tags]    Logs    Query    Gcloud    GCP    Errors    Common
    [Documentation]    Fetches logs from a Google Cloud Project and filters for a count of common error messages.
    ${cmd}    Set Variable    gcloud auth activate-service-account --key-file=$GOOGLE_APPLICATION_CREDENTIALS && gcloud logging read "severity>=${SEVERITY}${ADD_FILTERS}" --freshness=120m --limit=50 --format=json
    ${rsp}=    RW.CLI.Run Cli
    ...    cmd=${cmd}
    ...    env=${env}
    ...    secret_file__gcp_credentials_json=${gcp_credentials_json}
    ${namespace_list}=       RW.CLI.Parse Cli Json Output
    ...    rsp=${rsp}
    ...    extract_path_to_var__namespaces=[].resource.labels.namespace_name
    ...    assign_stdout_from_var=namespaces
    ${namespace_counts}=    Evaluate    {c: 0 for c in ${namespace_list.stdout}}
    ${namespace_counts}=    Evaluate    {k: ${namespace_list.stdout}.count(k) for k in ${namespace_counts}.keys()}
    ${common_namespace}=    Evaluate    max(${namespace_counts}, key=${namespace_counts}.get)
    ${cluster_list}=       RW.CLI.Parse Cli Json Output
    ...    rsp=${rsp}
    ...    extract_path_to_var__clusters=[].resource.labels.cluster_name
    ...    assign_stdout_from_var=clusters
    ${cluster_counts}=    Evaluate    {c: 0 for c in ${cluster_list.stdout}}
    ${cluster_counts}=    Evaluate    {k: ${cluster_list.stdout}.count(k) for k in ${cluster_counts}.keys()}
    ${common_cluster}=    Evaluate    max(${cluster_counts}, key=${cluster_counts}.get)
    ${entry_count}=    RW.CLI.Parse Cli Json Output
    ...    rsp=${rsp}
    ...    extract_path_to_var__count=length(@)
    ...    count__raise_issue_if_gt=0
    ...    set_severity_level=4
    ...    set_issue_expected=No filtered log entries returned by the gcloud query: ${cmd} 
    ...    set_issue_title=Found Errors During GCP Log Inspection
    ...    set_issue_actual=Found results from the command: ${cmd}
    ...    set_issue_details=Using the Gcloud log query "severity>=${SEVERITY}${ADD_FILTERS}" we found $count issues.\nSee output for more details:\n $_stdout
    ...    assign_stdout_from_var=count
    RW.Core.Add Pre To Report    Log Inspection Results:
    RW.Core.Add Pre To Report    Entries Count Of Potential Issues: ${entry_count.stdout}
    RW.Core.Add Pre To Report    Cluster With Most Potential Issues: ${common_cluster}
    RW.Core.Add Pre To Report    Namespace With Most Potential Issues: ${common_namespace}
    RW.Core.Add Pre To Report    Cluster Results: ${cluster_counts}
    RW.Core.Add Pre To Report    Namespace Results: ${namespace_counts}
    RW.Core.Add Pre To Report    \n\n
    RW.Core.Add Pre To Report    Full Logs:\n ${rsp.stdout}
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Commands Used: ${history}
    