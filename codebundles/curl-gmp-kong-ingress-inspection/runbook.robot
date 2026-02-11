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
Library             OperatingSystem

Suite Setup         Suite Initialization


*** Tasks ***
Check If Kong Ingress HTTP Error Rate Violates HTTP Error Threshold in GCP Project `${GCP_PROJECT_ID}`
    [Documentation]    Fetches HTTP Error metrics for the Kong ingress host and service from GMP and performs an inspection on the results. If there are currently any results with more than the defined HTTP error threshold, their route and service names will be surfaced for further troubleshooting.
    [Tags]    curl    http    ingress    errors    metrics    kong    gmp    access:read-only    data:config
    ${gmp_rsp}=    RW.CLI.Run Cli
    ...    cmd=gcloud auth activate-service-account --key-file=$GOOGLE_APPLICATION_CREDENTIALS && response=$(curl -s -d "query=rate(kong_http_requests_total{service='${INGRESS_SERVICE}',code=~'${HTTP_ERROR_CODES}'}[${TIME_SLICE}]) > ${HTTP_ERROR_RATE_THRESHOLD}" -H "Authorization: Bearer $(gcloud auth print-access-token)" 'https://monitoring.googleapis.com/v1/projects/runwhen-nonprod-sandbox/location/global/prometheus/api/v1/query') && echo "$response" | jq -e '.data.result | length > 0' && echo "$response" | jq -r '.data.result[] | "Route:" + .metric.route + " Service:" + .metric.service + " Kong Instance:" + .metric.instance + " HTTP Error Count:" + .value[1]' || echo "No HTTP Error threshold violations found for ${INGRESS_SERVICE}."
    ...    show_in_rwl_cheatsheet=true
    ...    render_in_commandlist=true
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ${ingress_name}=    RW.CLI.Run Cli
    ...    cmd=cat << 'EOF' | awk -F'.' '{print $4}'\n${INGRESS_SERVICE}\nEOF
    ...    include_in_history=False
    ${namespace_name}=    RW.CLI.Run Cli
    ...    cmd=cat << 'EOF' | awk -F'.' '{print $1}'\n${INGRESS_SERVICE}\nEOF
    ...    include_in_history=False
    # Check if HTTP error codes are detected
    ${contains_route_1}=    Run Keyword And Return Status    Should Contain    ${gmp_rsp.stdout}    Route
    IF    ${contains_route_1}
        RW.Core.Add Issue
        ...    severity=3
        ...    expected=The ingress should not have any HTTP responses error codes `${HTTP_ERROR_CODES}` less than a rate of `${HTTP_ERROR_RATE_THRESHOLD}`
        ...    actual=We found the following HTTP error codes `${HTTP_ERROR_CODES}` associated with the ingress
        ...    title=Detected HTTP Error Codes Across Network for Ingress `${INGRESS_SERVICE}`
        ...    details=The returned output: ${gmp_rsp.stdout} indicates there's HTTP error codes associated with this ingress and service. You need to investigate the application associated with: `${INGRESS_SERVICE}`
        ...    reproduce_hint=Check ingress and service health status
        ...    next_steps=Check the health status of the Ingress object `${ingress_name.stdout}` in namespace `${namespace_name.stdout}`
    END
    ${gmp_json}=    RW.CLI.Run Cli
    ...    cmd=gcloud auth activate-service-account --key-file=$GOOGLE_APPLICATION_CREDENTIALS && curl -s -d "query=rate(kong_http_requests_total{service='${INGRESS_SERVICE}',code=~'${HTTP_ERROR_CODES}'}[${TIME_SLICE}])" -H "Authorization: Bearer $(gcloud auth print-access-token)" 'https://monitoring.googleapis.com/v1/projects/runwhen-nonprod-sandbox/location/global/prometheus/api/v1/query' | jq .
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Commands Used: ${history}
    RW.Core.Add Pre To Report    HTTP Error Violation & Details:\n${gmp_rsp.stdout}
    RW.Core.Add Pre To Report    GMP Json Data:\n${gmp_json.stdout}

Check If Kong Ingress HTTP Request Latency Violates Threshold in GCP Project `${GCP_PROJECT_ID}`
    [Documentation]    Fetches metrics for the Kong ingress 99th percentile request latency from GMP and performs an inspection on the results. If there are currently any results with more than the defined request latency threshold, their route and service names will be surfaced for further troubleshooting.
    [Tags]    curl    request    ingress    latency    http    kong    gmp    access:read-only    data:config
    ${gmp_rsp}=    RW.CLI.Run Cli
    ...    cmd=gcloud auth activate-service-account --key-file=$GOOGLE_APPLICATION_CREDENTIALS && response=$(curl -s -d "query=histogram_quantile(0.99, sum(rate(kong_request_latency_ms_bucket{service='${INGRESS_SERVICE}'}[${TIME_SLICE}])) by (le)) > ${REQUEST_LATENCY_THRESHOLD}" -H "Authorization: Bearer $(gcloud auth print-access-token)" 'https://monitoring.googleapis.com/v1/projects/runwhen-nonprod-sandbox/location/global/prometheus/api/v1/query') && echo "$response" | jq -e '.data.result | length > 0' && echo "$response" | jq -r '.data.result[] | "Service: ${INGRESS_SERVICE}" + " HTTP Request Latency(ms):" + .value[1]' || echo "No HTTP request latency threshold violations found for ${INGRESS_SERVICE}."
    ...    show_in_rwl_cheatsheet=true
    ...    render_in_commandlist=true
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ${ingress_name}=    RW.CLI.Run Cli
    ...    cmd=cat << 'EOF' | awk -F'.' '{print $4}'\n${INGRESS_SERVICE}\nEOF
    ...    include_in_history=False
    ${service_name}=    RW.CLI.Run Cli
    ...    cmd=cat << 'EOF' | awk -F'.' '{print $2}'\n${INGRESS_SERVICE}\nEOF
    ...    include_in_history=False
    ${namespace_name}=    RW.CLI.Run Cli
    ...    cmd=cat << 'EOF' | awk -F'.' '{print $1}'\n${INGRESS_SERVICE}\nEOF
    ...    include_in_history=False
    # Check if HTTP request latencies are detected
    ${contains_route_2}=    Run Keyword And Return Status    Should Contain    ${gmp_rsp.stdout}    Route
    IF    ${contains_route_2}
        RW.Core.Add Issue
        ...    severity=3
        ...    expected=The ingress should not have any HTTP request latencies greater than `${REQUEST_LATENCY_THRESHOLD}`
        ...    actual=We found HTTP request latencies greater than `${REQUEST_LATENCY_THRESHOLD}` associated with the ingress
        ...    title=Detected HTTP Request Latencies in Network for Ingress `${INGRESS_SERVICE}`
        ...    details=The returned output: ${gmp_rsp.stdout} indicates there's high HTTP request latencies. You need to investigate the application associated with: `${INGRESS_SERVICE}` or the Kong ingress controller.
        ...    reproduce_hint=Check ingress performance and backend service response times
        ...    next_steps=Troubleshoot Namespace `${namespace_name.stdout}` Services and Application Workloads for HTTP-related errors.
    END
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Commands Used: ${history}
    RW.Core.Add Pre To Report    HTTP Request Latency Within Acceptable Parameters:\n${gmp_rsp.stdout}

Check If Kong Ingress Controller Reports Upstream Errors in GCP Project `${GCP_PROJECT_ID}`
    [Documentation]    Fetches metrics for the Kong ingress controller related to upstream healthchecks or dns errors.
    [Tags]    curl    request    ingress    upstream    healthcheck    dns    errrors    http    kong    gmp   access:read-only    data:config
    ${gmp_healthchecks_off_rsp}=    RW.CLI.Run Cli
    ...    cmd=gcloud auth activate-service-account --key-file=$GOOGLE_APPLICATION_CREDENTIALS && response=$(curl -s -d "query=kong_upstream_target_health{upstream='${INGRESS_UPSTREAM}',state='healthchecks_off'} > 0" -H "Authorization: Bearer $(gcloud auth print-access-token)" 'https://monitoring.googleapis.com/v1/projects/runwhen-nonprod-sandbox/location/global/prometheus/api/v1/query') && echo "$response" | jq -e '.data.result | length > 0' && echo "$response" | jq -r '.data.result[] | "Service: ${INGRESS_UPSTREAM}" + " Healthchecks Disabled!' || echo "${INGRESS_UPSTREAM} has healthchecks enabled."
    ...    show_in_rwl_cheatsheet=true
    ...    render_in_commandlist=true
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}

    # Check if Kong healthchecks are disabled
    ${contains_disabled}=    Run Keyword And Return Status    Should Contain    ${gmp_healthchecks_off_rsp.stdout}    Disabled
    IF    ${contains_disabled}
        RW.Core.Add Issue
        ...    severity=3
        ...    expected=The Kong ingress should have healthchecks enabled for `${INGRESS_UPSTREAM}`
        ...    actual=We found Kong healthchecks disabled
        ...    title=Detected Kong Ingress Upstream Healthchecks Disabled for `${INGRESS_UPSTREAM}`
        ...    details=The returned output: ${gmp_healthchecks_off_rsp.stdout} indicates Kong ingress upstream healthchecks are disabled for `${INGRESS_UPSTREAM}`.
        ...    reproduce_hint=Check Kong ingress configuration and upstream settings
        ...    next_steps=Modify your infrastructure definition for the Ingress `${INGRESS_UPSTREAM}` to have healthchecks enabled.
    END
    ${gmp_healthchecks_rsp}=    RW.CLI.Run Cli
    ...    cmd=gcloud auth activate-service-account --key-file=$GOOGLE_APPLICATION_CREDENTIALS && response=$(curl -s -d "query=kong_upstream_target_health{upstream='${INGRESS_UPSTREAM}',state=~'dns_error|unhealthy'} > 0" -H "Authorization: Bearer $(gcloud auth print-access-token)" 'https://monitoring.googleapis.com/v1/projects/runwhen-nonprod-sandbox/location/global/prometheus/api/v1/query') && echo "$response" | jq -e '.data.result | length > 0' && echo "$response" | jq -r '.data.result[] | "Issue detected with Service: ${INGRESS_UPSTREAM}" + " Healthcheck subsystem-state: " + .metric.subsystem + "-" + .metric.state + " Target: " + .metric.target' || echo "${INGRESS_UPSTREAM} is reported as healthy from the Kong ingress controller."
    ...    show_in_rwl_cheatsheet=true
    ...    render_in_commandlist=true
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    # Check if Kong healthcheck errors are detected
    ${contains_detected}=    Run Keyword And Return Status    Should Contain    ${gmp_healthchecks_rsp.stdout}    detected
    IF    ${contains_detected}
        RW.Core.Add Issue
        ...    severity=3
        ...    expected=The Kong ingress should report healthy status for `${INGRESS_UPSTREAM}`
        ...    actual=We found Kong healthcheck errors
        ...    title=Detected Kong Ingress Upstream Healthcheck Errors for `${INGRESS_UPSTREAM}`
        ...    details=The returned output: ${gmp_healthchecks_rsp.stdout} indicates Kong ingress upstream healthchecks are reported unhealthy for `${INGRESS_UPSTREAM}`.
        ...    reproduce_hint=Check Kong ingress upstream health and backend service status
        ...    next_steps=Investigate upstream service health and Kong ingress controller configuration
    END
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
    ${OS_PATH}=    Get Environment Variable    PATH
    Set Suite Variable    ${GCLOUD_SERVICE}    ${GCLOUD_SERVICE}
    Set Suite Variable    ${gcp_credentials}    ${gcp_credentials}
    Set Suite Variable    ${GCP_PROJECT_ID}    ${GCP_PROJECT_ID}
    Set Suite Variable    ${REQUEST_LATENCY_THRESHOLD}    ${REQUEST_LATENCY_THRESHOLD}
    Set Suite Variable    ${INGRESS_SERVICE}    ${INGRESS_SERVICE}
    Set Suite Variable    ${INGRESS_UPSTREAM}    ${INGRESS_UPSTREAM}
    Set Suite Variable    ${HTTP_ERROR_RATE_THRESHOLD}    ${HTTP_ERROR_RATE_THRESHOLD}
    Set Suite Variable    ${TIME_SLICE}    ${TIME_SLICE}
    Set Suite Variable    ${HTTP_ERROR_CODES}    ${HTTP_ERROR_CODES}
    Set Suite Variable
    ...    ${env}
    ...    {"CLOUDSDK_CORE_PROJECT":"${GCP_PROJECT_ID}","GOOGLE_APPLICATION_CREDENTIALS":"./${gcp_credentials.key}","PATH":"$PATH:${OS_PATH}"}

