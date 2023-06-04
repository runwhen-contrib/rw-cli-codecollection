*** Settings ***
Documentation       Collects Kong ingress host metrics from GMP on GCP and inspects the results for ingress with a HTTP error code rate greater than zero
...                 over a configurable duration and raises issues based on the number of ingress with error codes.
Metadata            Author    Shea Stewart
Metadata            Display Name    GKE Kong Ingress Host Triage 
Metadata            Supports    GCP,GMP,Ingress,Kong,Metrics
Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform

Suite Setup         Suite Initialization

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
    ${HTTP_ERROR_CODES}=    RW.Core.Import User Variable    HTTP_ERROR_CODES
    ...    type=string
    ...    description=Specify the HTTP status codes that will be included when calculating the error rate in promql compatible pattern.
    ...    pattern=\w*
    ...    example=5.* (matches any 500 error code)
    ...    default=5.*
    ${HTTP_ERROR_RATE_WINDOW}=    RW.Core.Import User Variable    HTTP_ERROR_RATE_WINDOW
    ...    type=string
    ...    description=Specify the window of time used to measure the rate. 
    ...    pattern=\w*
    ...    example=1m
    ...    default=1m
    ${HTTP_ERROR_RATE_THRESHOLD}=    RW.Core.Import User Variable    HTTP_ERROR_RATE_THRESHOLD
    ...    type=string
    ...    description=Specify the error rate threshold that is considered unhealthy. Measured in errors/s.
    ...    pattern=\w*
    ...    example=0.5
    ...    default=0.5
    ${INGRESS_UPSTREAM}=    RW.Core.Import User Variable    INGRESS_UPSTREAM
    ...    type=string
    ...    description=The name of the upstream target associated with the ingress object. This is the prometheus label named `upstream`. Typically in the format of the local dns address in the namespace, such as [service-name].[namespace-name].[service-port].svc
    ...    pattern=\w*
    ...    example=frontend-external.online-boutique.80.svc
    ${INGRESS_SERVICE}=    RW.Core.Import User Variable    INGRESS_SERVICE
    ...    type=string
    ...    description=The name of the service that related to the ingress object. This is the prometheus label named `service`. Typically in the form of [namespace].[object-name].[service-name].[service-port]
    ...    pattern=\w*
    ...    example=online-boutique.ob.frontend-external.80
    ${REQUEST_LATENCY_THRESHOLD}=    RW.Core.Import User Variable    REQUEST_LATENCY_THRESHOLD
    ...    type=string
    ...    description=The threshold in ms for request latency to be considered unhealthy. 
    ...    pattern=\w*
    ...    example=100
    Set Suite Variable    ${GCLOUD_SERVICE}    ${GCLOUD_SERVICE}
    Set Suite Variable    ${gcp_credentials_json}    ${gcp_credentials_json}
    Set Suite Variable    ${GCP_PROJECT_ID}    ${GCP_PROJECT_ID}
    Set Suite Variable    ${env}    {"CLOUDSDK_CORE_PROJECT":"${GCP_PROJECT_ID}","GOOGLE_APPLICATION_CREDENTIALS":"./${gcp_credentials_json.key}"}


*** Tasks ***
Check If Kong Ingress HTTP Error Rate Voilates HTTP Error Threshold
    [Documentation]    Fetches metrics for the Kong ingress host and service from GMP and performs an inspection on the results.
    ...     If there are currently any results with more than the defined HTTP error threshold, their route and service names will be surfaced for further troubleshooting.
    [Tags]    cURL    HTTP    Ingress    Latency    Errors    Metrics    Controller    Kong    GMP
    ${gmp_rsp}=    RW.CLI.Run Cli
    ...    cmd=gcloud auth activate-service-account --key-file=$GOOGLE_APPLICATION_CREDENTIALS && response=$(curl -s -d "query=rate(kong_http_requests_total{service='${INGRESS_SERVICE}',code=~'${HTTP_ERROR_CODES}'}[${HTTP_ERROR_RATE_WINDOW}]) > ${HTTP_ERROR_RATE_THRESHOLD}" -H "Authorization: Bearer $(gcloud auth print-access-token)" 'https://monitoring.googleapis.com/v1/projects/runwhen-nonprod-sandbox/location/global/prometheus/api/v1/query') && echo "$response" | jq -e '.data.result | length > 0' && echo "$response" | jq -r '.data.result[] | "Route:" + .metric.route + " Ingress:" + .metric.ingress + " Namespace:" + .metric.export_namespace + " Service:" + .metric.service + " Kong Instance:" + .metric.instance + " HTTP Error Count:" + .value[1]' || echo "No HTTP Error threshold violations found for ${INGRESS_SERVICE}."
    ...    render_in_commandlist=true
    ...    target_service=${GCLOUD_SERVICE}
    ...    env=${env}
    ...    secret_file__gcp_credentials_json=${gcp_credentials_json}
    RW.CLI.Parse Cli Output By Line
    ...    rsp=${gmp_rsp}
    ...    set_severity_level=3
    ...    set_issue_expected=The ingress in $_line should not have any HTTP responses error codes ${HTTP_ERROR_CODES} less than a rate of ${HTTP_ERROR_RATE_THRESHOLD}
    ...    set_issue_actual=We found the following HTTP error codes ${HTTP_ERROR_CODES} associated with the ingress in $_line
    ...    set_issue_title=Detected HTTP Error Codes Across Network
    ...    set_issue_details=The returned stdout line: $_line indicates there's HTTP error codes associated with this ingress and service! You need to investigate the application associated with: ${INGRESS_SERVICE}
    ...    _line__raise_issue_if_contains=Route
    ${gmp_json}=    RW.CLI.Run Cli
    ...    cmd=gcloud auth activate-service-account --key-file=$GOOGLE_APPLICATION_CREDENTIALS && curl -s -d "query=rate(kong_http_requests_total{service='${INGRESS_SERVICE}',code=~'${HTTP_ERROR_CODES}'}[${HTTP_ERROR_RATE_WINDOW}])" -H "Authorization: Bearer $(gcloud auth print-access-token)" 'https://monitoring.googleapis.com/v1/projects/runwhen-nonprod-sandbox/location/global/prometheus/api/v1/query' | jq . 
    ...    target_service=${GCLOUD_SERVICE}
    ...    env=${env}
    ...    secret_file__gcp_credentials_json=${gcp_credentials_json}
    ${ingress_info}    Set Variable    ${gmp_rsp.stdout}
    IF    """${ingress_info}""" == ""
        ${ingress_info}    Set Variable    No ingress with error codes: ${HTTP_ERROR_CODES} within the timeframe ${HTTP_ERROR_RATE_WINDOW}
    END
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Commands Used: ${history}
    RW.Core.Add Pre To Report    HTTP Error Voilation & Details:\n${ingress_info}
    RW.Core.Add Pre To Report    GMP Json Data:\n${gmp_json.stdout}
    
