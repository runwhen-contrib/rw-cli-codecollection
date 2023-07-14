*** Settings ***
Documentation       Collects Kong ingress host metrics from GMP on GCP and inspects the results for ingress with a HTTP error code rate greater than zero
...                 over a configurable duration and raises issues based on the number of ingress with error codes.
Metadata            Author    stewartshea
Metadata            Display Name    GKE Kong Ingress Host Triage
Metadata            Supports    GCP,GMP,Ingress,Kong,Metrics

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform

Suite Setup         Suite Initialization


*** Tasks ***
Check If Kong Ingress HTTP Error Rate Violates HTTP Error Threshold
    [Documentation]    Fetches HTTP Error metrics for the Kong ingress host and service from GMP and performs an inspection on the results. If there are currently any results with more than the defined HTTP error threshold, their route and service names will be surfaced for further troubleshooting.
    [Tags]    curl    http    ingress    errors    metrics    kong    gmp
    ${gmp_rsp}=    RW.CLI.Run Cli
    ...    cmd=gcloud auth activate-service-account --key-file=$GOOGLE_APPLICATION_CREDENTIALS && response=$(curl -s -d "query=rate(kong_http_requests_total{service='${INGRESS_SERVICE}',code=~'${HTTP_ERROR_CODES}'}[${TIME_SLICE}]) > ${HTTP_ERROR_RATE_THRESHOLD}" -H "Authorization: Bearer $(gcloud auth print-access-token)" 'https://monitoring.googleapis.com/v1/projects/runwhen-nonprod-sandbox/location/global/prometheus/api/v1/query') && echo "$response" | jq -e '.data.result | length > 0' && echo "$response" | jq -r '.data.result[] | "Route:" + .metric.route + " Service:" + .metric.service + " Kong Instance:" + .metric.instance + " HTTP Error Count:" + .value[1]' || echo "No HTTP Error threshold violations found for ${INGRESS_SERVICE}."
    ...    render_in_commandlist=true
    ...    target_service=${GCLOUD_SERVICE}
    ...    env=${env}
    ...    secret_file__gcp_credentials_json=${gcp_credentials_json}
    ${svc_name}=    RW.CLI.Run Cli
    ...    cmd=echo "${gmp_rsp.stdout}" | grep -oP '(?<=Service:)[^ ]*' | grep -oP '[^.]*(?=.80)'
    ...    target_service=${GCLOUD_SERVICE}
    RW.CLI.Parse Cli Output By Line
    ...    rsp=${gmp_rsp}
    ...    set_severity_level=3
    ...    set_issue_expected=The ingress in $_line should not have any HTTP responses error codes ${HTTP_ERROR_CODES} less than a rate of ${HTTP_ERROR_RATE_THRESHOLD}
    ...    set_issue_actual=We found the following HTTP error codes ${HTTP_ERROR_CODES} associated with the ingress in $_line
    ...    set_issue_title=Detected HTTP Error Codes Across Network
    ...    set_issue_details=The returned stdout line: $_line indicates there's HTTP error codes associated with this ingress and service. You need to investigate the application associated with: ${INGRESS_SERVICE}
    ...    set_issue_next_steps=${svc_name.stdout} Check Deployment
    ...    _line__raise_issue_if_contains=Route
    ${gmp_json}=    RW.CLI.Run Cli
    ...    cmd=gcloud auth activate-service-account --key-file=$GOOGLE_APPLICATION_CREDENTIALS && curl -s -d "query=rate(kong_http_requests_total{service='${INGRESS_SERVICE}',code=~'${HTTP_ERROR_CODES}'}[${TIME_SLICE}])" -H "Authorization: Bearer $(gcloud auth print-access-token)" 'https://monitoring.googleapis.com/v1/projects/runwhen-nonprod-sandbox/location/global/prometheus/api/v1/query' | jq .
    ...    target_service=${GCLOUD_SERVICE}
    ...    env=${env}
    ...    secret_file__gcp_credentials_json=${gcp_credentials_json}
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Commands Used: ${history}
    RW.Core.Add Pre To Report    HTTP Error Violation & Details:\n${gmp_rsp.stdout}
    RW.Core.Add Pre To Report    GMP Json Data:\n${gmp_json.stdout}

Check If Kong Ingress HTTP Request Latency Violates Threshold
    [Documentation]    Fetches metrics for the Kong ingress 99th percentile request latency from GMP and performs an inspection on the results. If there are currently any results with more than the defined request latency threshold, their route and service names will be surfaced for further troubleshooting.
    [Tags]    curl    request    ingress    latency    http    kong    gmp
    ${gmp_rsp}=    RW.CLI.Run Cli
    ...    cmd=gcloud auth activate-service-account --key-file=$GOOGLE_APPLICATION_CREDENTIALS && response=$(curl -s -d "query=histogram_quantile(0.99, sum(rate(kong_request_latency_ms_bucket{service='${INGRESS_SERVICE}'}[${TIME_SLICE}])) by (le)) > ${REQUEST_LATENCY_THRESHOLD}" -H "Authorization: Bearer $(gcloud auth print-access-token)" 'https://monitoring.googleapis.com/v1/projects/runwhen-nonprod-sandbox/location/global/prometheus/api/v1/query') && echo "$response" | jq -e '.data.result | length > 0' && echo "$response" | jq -r '.data.result[] | "Service: ${INGRESS_SERVICE}" + " HTTP Request Latency(ms):" + .value[1]' || echo "No HTTP request latency threshold violations found for ${INGRESS_SERVICE}."
    ...    render_in_commandlist=true
    ...    target_service=${GCLOUD_SERVICE}
    ...    env=${env}
    ...    secret_file__gcp_credentials_json=${gcp_credentials_json}
    RW.CLI.Parse Cli Output By Line
    ...    rsp=${gmp_rsp}
    ...    set_severity_level=3
    ...    set_issue_expected=The ingress in $_line should not have any HTTP request latencies greater than ${REQUEST_LATENCY_THRESHOLD}
    ...    set_issue_actual=We found HTTP request latencies greater than ${REQUEST_LATENCY_THRESHOLD} associated with the ingress in $_line
    ...    set_issue_title=Detected HTTP Request Latencies in network
    ...    set_issue_details=The returned stdout line: $_line indicates there's high HTTP request latencies. You need to investigate the application associated with: ${INGRESS_SERVICE} or the Kong ingress controller.
    ...    _line__raise_issue_if_contains=Route
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Commands Used: ${history}
    RW.Core.Add Pre To Report    HTTP Request Latency Within Acceptable Parameters:\n${gmp_rsp.stdout}

Check If Kong Ingress Controller Reports Upstream Errors
    [Documentation]    Fetches metrics for the Kong ingress controller related to upstream healthchecks or dns errors.
    [Tags]    curl    request    ingress    upstream    healthcheck    dns    errrors    http    kong    gmp
    ${gmp_healthchecks_off_rsp}=    RW.CLI.Run Cli
    ...    cmd=gcloud auth activate-service-account --key-file=$GOOGLE_APPLICATION_CREDENTIALS && response=$(curl -s -d "query=kong_upstream_target_health{upstream='${INGRESS_UPSTREAM}',state='healthchecks_off'} > 0" -H "Authorization: Bearer $(gcloud auth print-access-token)" 'https://monitoring.googleapis.com/v1/projects/runwhen-nonprod-sandbox/location/global/prometheus/api/v1/query') && echo "$response" | jq -e '.data.result | length > 0' && echo "$response" | jq -r '.data.result[] | "Service: ${INGRESS_UPSTREAM}" + " Healthchecks Disabled!' || echo "${INGRESS_UPSTREAM} has healthchecks enabled."
    ...    render_in_commandlist=true
    ...    target_service=${GCLOUD_SERVICE}
    ...    env=${env}
    ...    secret_file__gcp_credentials_json=${gcp_credentials_json}
    RW.CLI.Parse Cli Output By Line
    ...    rsp=${gmp_healthchecks_off_rsp}
    ...    set_severity_level=3
    ...    set_issue_expected=The Kong ingress in $_line should not have healthchecks enabled for ${INGRESS_UPSTREAM}
    ...    set_issue_actual=We found Kong healthchecks disabled in $_line
    ...    set_issue_title=Detected Kong Ingress Upstream healthchecks disabled
    ...    set_issue_details=The returned stdout line: $_line indicates Kong ingress upstream healthchecks are disabled for ${INGRESS_UPSTREAM}.
    ...    _line__raise_issue_if_contains=Disabled
    ${gmp_healthchecks_rsp}=    RW.CLI.Run Cli
    ...    cmd=gcloud auth activate-service-account --key-file=$GOOGLE_APPLICATION_CREDENTIALS && response=$(curl -s -d "query=kong_upstream_target_health{upstream='${INGRESS_UPSTREAM}',state=~'dns_error|unhealthy'} > 0" -H "Authorization: Bearer $(gcloud auth print-access-token)" 'https://monitoring.googleapis.com/v1/projects/runwhen-nonprod-sandbox/location/global/prometheus/api/v1/query') && echo "$response" | jq -e '.data.result | length > 0' && echo "$response" | jq -r '.data.result[] | "Issue detected with Service: ${INGRESS_UPSTREAM}" + " Healthcheck subsystem-state: " + .metric.subsystem + "-" + .metric.state + " Target: " + .metric.target' || echo "${INGRESS_UPSTREAM} is reported as healthy from the Kong ingress controller."
    ...    render_in_commandlist=true
    ...    target_service=${GCLOUD_SERVICE}
    ...    env=${env}
    ...    secret_file__gcp_credentials_json=${gcp_credentials_json}
    RW.CLI.Parse Cli Output By Line
    ...    rsp=${gmp_healthchecks_rsp}
    ...    set_severity_level=3
    ...    set_issue_expected=The Kong ingress in $_line is reporting health issues ${INGRESS_UPSTREAM}
    ...    set_issue_actual=We found Kong healthcheck errors in $_line
    ...    set_issue_title=Detected Kong Ingress Upstream healthcheck errors
    ...    set_issue_details=The returned stdout line: $_line indicates Kong ingress upstream healthchecks are reported unhealthy ${INGRESS_UPSTREAM}.
    ...    _line__raise_issue_if_contains=detected
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Commands Used: ${history}
    RW.Core.Add Pre To Report    Kong Upstream Healthchecks Enabled:\n${gmp_healthchecks_off_rsp.stdout}
    RW.Core.Add Pre To Report    Kong Upstream Healthcheck Issues:\n${gmp_healthchecks_rsp.stdout}


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
    ${HTTP_ERROR_CODES}=    RW.Core.Import User Variable
    ...    HTTP_ERROR_CODES
    ...    type=string
    ...    description=Specify the HTTP status codes that will be included when calculating the error rate in promql compatible pattern.
    ...    pattern=\w*
    ...    example=5.* (matches any 500 error code)
    ...    default=5.*
    ${TIME_SLICE}=    RW.Core.Import User Variable    TIME_SLICE
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
    ${INGRESS_UPSTREAM}=    RW.Core.Import User Variable
    ...    INGRESS_UPSTREAM
    ...    type=string
    ...    description=The name of the upstream target associated with the ingress object. This is the prometheus label named `upstream`. Typically in the format of the local dns address in the namespace, such as [service-name].[namespace-name].[service-port].svc
    ...    pattern=\w*
    ...    example=frontend-external.online-boutique.80.svc
    ${INGRESS_SERVICE}=    RW.Core.Import User Variable
    ...    INGRESS_SERVICE
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
    Set Suite Variable    ${REQUEST_LATENCY_THRESHOLD}    ${REQUEST_LATENCY_THRESHOLD}
    Set Suite Variable    ${INGRESS_SERVICE}    ${INGRESS_SERVICE}
    Set Suite Variable    ${INGRESS_UPSTREAM}    ${INGRESS_UPSTREAM}
    Set Suite Variable    ${HTTP_ERROR_RATE_THRESHOLD}    ${HTTP_ERROR_RATE_THRESHOLD}
    Set Suite Variable    ${TIME_SLICE}    ${TIME_SLICE}
    Set Suite Variable    ${HTTP_ERROR_CODES}    ${HTTP_ERROR_CODES}
    Set Suite Variable
    ...    ${env}
    ...    {"CLOUDSDK_CORE_PROJECT":"${GCP_PROJECT_ID}","GOOGLE_APPLICATION_CREDENTIALS":"./${gcp_credentials_json.key}"}
