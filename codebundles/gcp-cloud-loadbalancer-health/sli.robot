*** Settings ***
Documentation       Scores GCP Cloud Load Balancer health as a 0-1 value averaged across four dimensions: SSL certificate health, backend health, error rate, and latency performance.
Metadata            Author    rw-codebundle-agent
Metadata            Display Name    GCP Cloud Load Balancer Health
Metadata            Supports    GCP,Cloud Load Balancing,Load Balancer
Force Tags          GCP    Cloud Load Balancing    Load Balancer

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             OperatingSystem

Suite Setup         Suite Initialization

*** Tasks ***
Score SSL Certificate Health for Load Balancers in `${GCP_PROJECT_ID}`
    [Documentation]    Scores 1.0 if no SSL certificates expire within SSL_WARNING_DAYS, 0.0 otherwise.
    [Tags]    gcloud    loadbalancer    ssl    gcp    ${GCP_PROJECT_ID}    data:config    access:read-only
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check_ssl_certificates.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ${issues_output}=    RW.CLI.Run Cli
    ...    cmd=jq length ssl_certificate_issues.json 2>/dev/null || echo 0
    ...    env=${env}
    ${ssl_score}=    Evaluate    1 if int(${issues_output.stdout}) == 0 else 0
    Set Suite Variable    ${ssl_score}
    RW.Core.Push Metric    ${issues_output.stdout}    sub_name=expiring_cert_count
    RW.Core.Push Metric    ${ssl_score}    sub_name=ssl_certificate_health

Score Backend Health for Load Balancers in `${GCP_PROJECT_ID}`
    [Documentation]    Scores the ratio of healthy backends to total backends across all load balancers (1.0 if none unhealthy).
    [Tags]    gcloud    loadbalancer    backend    gcp    ${GCP_PROJECT_ID}    data:state    access:read-only
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check_backend_health.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ${healthy_output}=    RW.CLI.Run Cli
    ...    cmd=jq '[.[] | select(.health_state=="HEALTHY")] | length' backend_health_report.json 2>/dev/null || echo 0
    ...    env=${env}
    ${total_output}=    RW.CLI.Run Cli
    ...    cmd=jq 'length' backend_health_report.json 2>/dev/null || echo 0
    ...    env=${env}
    ${backend_score}=    Evaluate    1 if int(${total_output.stdout or 0}) == 0 else (${healthy_output.stdout or 0} / ${total_output.stdout or 0})
    ${unhealthy_backend_count}=    Evaluate    int(${total_output.stdout or 0}) - int(${healthy_output.stdout or 0})
    Set Suite Variable    ${backend_score}
    RW.Core.Push Metric    ${unhealthy_backend_count}    sub_name=unhealthy_backend_count
    RW.Core.Push Metric    ${backend_score}    sub_name=backend_health

Score Load Balancer Error Rates in `${GCP_PROJECT_ID}`
    [Documentation]    Scores 1.0 if all load balancers are below ERROR_RATE_THRESHOLD, 0.0 otherwise.
    [Tags]    gcloud    loadbalancer    monitoring    gcp    ${GCP_PROJECT_ID}    data:metrics    access:read-only
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check_error_rates.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ${issues_output}=    RW.CLI.Run Cli
    ...    cmd=jq length error_rate_issues.json 2>/dev/null || echo 0
    ...    env=${env}
    ${error_score}=    Evaluate    1 if int(${issues_output.stdout}) == 0 else 0
    Set Suite Variable    ${error_score}
    RW.Core.Push Metric    ${issues_output.stdout}    sub_name=high_error_rate_count
    RW.Core.Push Metric    ${error_score}    sub_name=error_rate

Score Load Balancer Latency Performance in `${GCP_PROJECT_ID}`
    [Documentation]    Scores 1.0 if all load balancers are below LATENCY_THRESHOLD_MS, 0.0 otherwise.
    [Tags]    gcloud    loadbalancer    monitoring    gcp    ${GCP_PROJECT_ID}    data:metrics    access:read-only
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check_latency.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ${issues_output}=    RW.CLI.Run Cli
    ...    cmd=jq length latency_issues.json 2>/dev/null || echo 0
    ...    env=${env}
    ${latency_score}=    Evaluate    1 if int(${issues_output.stdout}) == 0 else 0
    Set Suite Variable    ${latency_score}
    RW.Core.Push Metric    ${issues_output.stdout}    sub_name=high_latency_count
    RW.Core.Push Metric    ${latency_score}    sub_name=latency_performance

Generate Aggregate Load Balancer Health Score for `${GCP_PROJECT_ID}`
    [Documentation]    Averages the four dimension sub-scores into the final 0-1 health score.
    [Tags]    gcloud    loadbalancer    gcp    ${GCP_PROJECT_ID}    data:metrics    access:read-only
    ${health_score}=    Evaluate    (${ssl_score} + ${backend_score} + ${error_score} + ${latency_score}) / 4
    ${health_score}=    Convert to Number    ${health_score}    2
    RW.Core.Add to Report    Load Balancer Health Score: ${health_score} -- ssl: ${ssl_score}, backend: ${backend_score}, error_rate: ${error_score}, latency: ${latency_score}
    RW.Core.Push Metric    ${health_score}

*** Keywords ***
Suite Initialization
    ${gcp_credentials}=    RW.Core.Import Secret    gcp_credentials
    ...    type=string
    ...    description=GCP service account json used to authenticate with GCP APIs.
    ...    pattern=\w*
    ...    example={"type": "service_account","project_id":"myproject-ID", ... super secret stuff ...}
    ${GCP_PROJECT_ID}=    RW.Core.Import User Variable    GCP_PROJECT_ID
    ...    type=string
    ...    description=The GCP Project ID that hosts the load balancers to check.
    ...    pattern=\w*
    ...    example=myproject-ID
    ${SSL_WARNING_DAYS}=    RW.Core.Import User Variable    SSL_WARNING_DAYS
    ...    type=string
    ...    description=Number of days before SSL certificate expiry to raise a warning.
    ...    pattern=^\d+$
    ...    default=30
    ${ERROR_RATE_THRESHOLD}=    RW.Core.Import User Variable    ERROR_RATE_THRESHOLD
    ...    type=string
    ...    description=Maximum acceptable 5xx error ratio.
    ...    pattern=^\d*\.?\d+$
    ...    default=0.01
    ${LATENCY_THRESHOLD_MS}=    RW.Core.Import User Variable    LATENCY_THRESHOLD_MS
    ...    type=string
    ...    description=Maximum acceptable P95 latency in milliseconds.
    ...    pattern=^\d+$
    ...    default=5000
    ${METRIC_LOOKBACK_PERIOD}=    RW.Core.Import User Variable    METRIC_LOOKBACK_PERIOD
    ...    type=string
    ...    description=Cloud Monitoring lookback period for metric queries (seconds).
    ...    pattern=^\d+s$
    ...    default=3600s
    Set Suite Variable    ${GCP_PROJECT_ID}    ${GCP_PROJECT_ID}
    Set Suite Variable    ${gcp_credentials}    ${gcp_credentials}
    Set Suite Variable    ${SSL_WARNING_DAYS}    ${SSL_WARNING_DAYS}
    Set Suite Variable    ${ERROR_RATE_THRESHOLD}    ${ERROR_RATE_THRESHOLD}
    Set Suite Variable    ${LATENCY_THRESHOLD_MS}    ${LATENCY_THRESHOLD_MS}
    Set Suite Variable    ${METRIC_LOOKBACK_PERIOD}    ${METRIC_LOOKBACK_PERIOD}
    ${OS_PATH}=    Get Environment Variable    PATH
    Set Suite Variable
    ...    ${env}
    ...    {"CLOUDSDK_CORE_PROJECT":"${GCP_PROJECT_ID}","PATH":"$PATH:${OS_PATH}","GCP_PROJECT_ID":"${GCP_PROJECT_ID}","SSL_WARNING_DAYS":"${SSL_WARNING_DAYS}","ERROR_RATE_THRESHOLD":"${ERROR_RATE_THRESHOLD}","LATENCY_THRESHOLD_MS":"${LATENCY_THRESHOLD_MS}","METRIC_LOOKBACK_PERIOD":"${METRIC_LOOKBACK_PERIOD}"}
    RW.CLI.Run CLI
    ...    cmd=gcloud auth activate-service-account --key-file="./${gcp_credentials.key}" || true
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
