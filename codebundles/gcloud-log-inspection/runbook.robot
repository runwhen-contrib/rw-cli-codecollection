*** Settings ***
Metadata          Author    Jonathan Funk
Metadata          Display Name    GCP Gcloud Log Inspection
Metadata          Supports    GCP,Gcloud,Google Monitoring
Documentation     Fetches logs from a GCP using a configurable query and raises an issue with details on the most common issue.
Suite Setup       Suite Initialization
Library           RW.Core
Library           RW.CLI

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
    ...    description=Extra optional filters to add to the gcloud log read request.  
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
    Set Suite Variable    ${SEVERITY}    ${SEVERITY}
    Set Suite Variable    ${GCLOUD_SERVICE}    ${GCLOUD_SERVICE}
    Set Suite Variable    ${gcp_credentials_json}    ${gcp_credentials_json}
    Set Suite Variable    ${GCP_PROJECT_ID}    ${GCP_PROJECT_ID}
    IF    "${ADD_FILTERS}" != ""
        ${ADD_FILTERS}=    Set Variable    \ AND ${ADD_FILTERS}        
    END
    Set Suite Variable    ${ADD_FILTERS}    ${ADD_FILTERS}
    Set Suite Variable    ${env}    {"CLOUDSDK_CORE_PROJECT":"${GCP_PROJECT_ID}","GOOGLE_APPLICATION_CREDENTIALS":"./${gcp_credentials_json.key}"}
    Set Suite Variable    ${auto_auth_prepend}    gcloud auth activate-service-account --key-file=$GOOGLE_APPLICATION_CREDENTIALS &&

*** Tasks ***
Fetch Error Logs For GCP Project
    [Tags]    Logs    Query    Gcloud    GCP    Errors    Common
    [Documentation]    Fetches logs from a Google Cloud Project and filters for a count of common messages.
    ${cmd}    Set Variable    ${auto_auth_prepend} gcloud logging read "severity>=${SEVERITY}${ADD_FILTERS}" --freshness=120m --limit=50 --format=json
    ${rsp}=    RW.CLI.Run Cli
    ...    cmd=${cmd}
    ...    target_service=${GCLOUD_SERVICE}
    ...    env=${env}
    ...    secret_file__gcp_credentials_json=${gcp_credentials_json}
    ${entry_count}=    RW.CLI.Parse Cli Json Output
    ...    rsp=${rsp}
    ...    extract_path_to_var__count=length(@)
    ...    count__raise_issue_if_gt=0
    ...    set_issue_expected=No filtered log entries returned by the gcloud query: ${cmd} 
    ...    set_issue_title=Found Errors During GCP Log Inspection
    ...    set_issue_actual=Found results from the command: ${cmd}
    ...    set_issue_details=We found: {_stdout}
    ...    assign_stdout_from_var=count
    #TODO: count up matching results and show most common as issue
    