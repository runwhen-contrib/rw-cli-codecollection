*** Settings ***
Documentation       Collects Nginx ingress host controller metrics from GMP on GCP and inspects the results for ingress with a HTTP error code rate greater than zero
...                 over a configurable duration and raises issues based on the number of ingress with error codes.
Metadata            Author    jon-funk
Metadata            Display Name    GKE Nginx Ingress Host Triage
Metadata            Supports    GCP,GMP,Ingress,Nginx,Metrics

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform

Suite Setup         Suite Initialization


*** Tasks ***
Fetch Nginx Ingress Metrics From GMP And Perform Inspection On Results
    [Documentation]    Fetches metrics for the Nginx ingress host from GMP and performs an inspection on the results.
    ...    If there are currently any results with more than zero errors, their name will be surfaced for further troubleshooting.
    [Tags]    curl    http    ingress    latency    errors    metrics    controller    nginx    gmp
    ${gmp_rsp}=    RW.CLI.Run Cli
    ...    cmd=gcloud auth activate-service-account --key-file=$GOOGLE_APPLICATION_CREDENTIALS && curl -d "query=rate(nginx_ingress_controller_requests{status=~'${ERROR_CODES}'}[${TIME_SLICE}]) > 0" -H "Authorization: Bearer $(gcloud auth print-access-token)" 'https://monitoring.googleapis.com/v1/projects/${GCP_PROJECT_ID}/location/global/prometheus/api/v1/query' | jq -r '.data.result[] | "Host:" + .metric.host + " Ingress:" + .metric.ingress + " Namespace:" + .metric.export_namespace + " Service:" + .metric.service'
    ...    render_in_commandlist=true
    ...    target_service=${GCLOUD_SERVICE}
    ...    env=${env}
    ...    secret_file__gcp_credentials_json=${gcp_credentials_json}
    ${gmp_json}=    RW.CLI.Run Cli
    ...    cmd=gcloud auth activate-service-account --key-file=$GOOGLE_APPLICATION_CREDENTIALS && curl -d "query=rate(nginx_ingress_controller_requests{status=~'${ERROR_CODES}'}[${TIME_SLICE}]) > 0" -H "Authorization: Bearer $(gcloud auth print-access-token)" 'https://monitoring.googleapis.com/v1/projects/${GCP_PROJECT_ID}/location/global/prometheus/api/v1/query'
    ...    render_in_commandlist=true
    ...    target_service=${GCLOUD_SERVICE}
    ...    env=${env}
    ...    secret_file__gcp_credentials_json=${gcp_credentials_json}
    ${service_name}=    RW.CLI.Parse Cli Json Output
    ...    rsp=${gmp_json}
    ...    extract_path_to_var__service_name=data.result[0].metric.service
    ...    assign_stdout_from_var=service_name
    RW.CLI.Parse Cli Output By Line
    ...    rsp=${gmp_rsp}
    ...    set_severity_level=3
    ...    set_issue_expected=The ingress in $_line should not have any HTTP responses with the following codes: ${ERROR_CODES}
    ...    set_issue_actual=We found the following HTTP error codes: ${ERROR_CODES} associated with the ingress in $_line
    ...    set_issue_title=Detected HTTP Error Codes Across Network
    ...    set_issue_details=HTTP error codes in ingress and service "$_line". Troubleshoot the application associated with: ${service_name.stdout}
    ...    _line__raise_issue_if_contains=Host
    ${ingress_info}=    Set Variable    ${gmp_rsp.stdout}
    IF    """${ingress_info}""" == ""
        ${ingress_info}=    Set Variable
        ...    No ingress with error codes: ${ERROR_CODES} within the timeframe ${TIME_SLICE}
    END
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Commands Used: ${history}
    RW.Core.Add Pre To Report    Ingress Info:\n${ingress_info}
    RW.Core.Add Pre To Report    GMP Json Data:\n${gmp_json.stdout}


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
    ${GCP_PROJECT_ID}=    RW.Core.Import User Variable    GCP_PROJECT_ID
    ...    type=string
    ...    description=The GCP Project ID to scope the API to.
    ...    pattern=\w*
    ...    example=myproject-ID
    ${TIME_SLICE}=    RW.Core.Import User Variable    TIME_SLICE
    ...    type=string
    ...    description=The amount of time to perform aggregations over.
    ...    pattern=\w*
    ...    example=60m
    ...    default=60m
    Set Suite Variable    ${TIME_SLICE}    ${TIME_SLICE}
    ${ERROR_CODES}=    RW.Core.Import User Variable    ERROR_CODES
    ...    type=string
    ...    description=Which http status codes to look for and classify as errors.
    ...    pattern=\w*
    ...    example=500
    ...    default=500|501|502
    Set Suite Variable    ${ERROR_CODES}    ${ERROR_CODES}
    Set Suite Variable    ${GCLOUD_SERVICE}    ${GCLOUD_SERVICE}
    Set Suite Variable    ${gcp_credentials_json}    ${gcp_credentials_json}
    Set Suite Variable    ${GCP_PROJECT_ID}    ${GCP_PROJECT_ID}
    Set Suite Variable
    ...    ${env}
    ...    {"CLOUDSDK_CORE_PROJECT":"${GCP_PROJECT_ID}","GOOGLE_APPLICATION_CREDENTIALS":"./${gcp_credentials_json.key}"}
