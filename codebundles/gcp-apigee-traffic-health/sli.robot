*** Settings ***
Documentation       Scores GCP Apigee runtime traffic and performance health as a 0-1 value averaged across four dimensions: error/fault rate, latency performance, throughput/anomaly status, and target/backend performance.
Metadata            Author    rw-codebundle-agent
Metadata            Display Name    GCP Apigee Traffic and Performance Health
Metadata            Supports    GCP,Apigee,API Management,Traffic Monitoring
Force Tags          GCP    Apigee    API Management    Traffic Monitoring

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             OperatingSystem

Suite Setup         Suite Initialization

*** Tasks ***
Score Apigee Error and Fault Rates in `${GCP_PROJECT_ID}`
    [Documentation]    Scores 1.0 if no proxies exceed ERROR_RATE_THRESHOLD, 0.0 otherwise.
    [Tags]    gcloud    apigee    monitoring    gcp    ${GCP_PROJECT_ID}    data:metrics    access:read-only
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

Score Apigee Latency Performance in `${GCP_PROJECT_ID}`
    [Documentation]    Scores 1.0 if no proxies exceed LATENCY_MS_THRESHOLD, 0.0 otherwise.
    [Tags]    gcloud    apigee    monitoring    gcp    ${GCP_PROJECT_ID}    data:metrics    access:read-only
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

Score Apigee Throughput and Anomalies in `${GCP_PROJECT_ID}`
    [Documentation]    Scores 1.0 if no throughput anomalies are detected, 0.0 otherwise.
    [Tags]    gcloud    apigee    monitoring    gcp    ${GCP_PROJECT_ID}    data:metrics    access:read-only
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check_throughput.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ${issues_output}=    RW.CLI.Run Cli
    ...    cmd=jq length throughput_issues.json 2>/dev/null || echo 0
    ...    env=${env}
    ${anomaly_score}=    Evaluate    1 if int(${issues_output.stdout}) == 0 else 0
    Set Suite Variable    ${anomaly_score}
    RW.Core.Push Metric    ${issues_output.stdout}    sub_name=throughput_anomaly_count
    RW.Core.Push Metric    ${anomaly_score}    sub_name=throughput_anomaly

Score Apigee Target and Backend Performance in `${GCP_PROJECT_ID}`
    [Documentation]    Scores 1.0 if no target servers exceed error or latency thresholds, 0.0 otherwise.
    [Tags]    gcloud    apigee    monitoring    gcp    ${GCP_PROJECT_ID}    data:metrics    access:read-only
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check_target_performance.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ${issues_output}=    RW.CLI.Run Cli
    ...    cmd=jq length target_performance_issues.json 2>/dev/null || echo 0
    ...    env=${env}
    ${target_score}=    Evaluate    1 if int(${issues_output.stdout}) == 0 else 0
    Set Suite Variable    ${target_score}
    RW.Core.Push Metric    ${issues_output.stdout}    sub_name=degraded_target_count
    RW.Core.Push Metric    ${target_score}    sub_name=target_performance

Generate Aggregate Apigee Health Score for `${APIGEE_ORG}`
    [Documentation]    Averages the four dimension sub-scores into the final 0-1 health score.
    [Tags]    gcloud    apigee    gcp    ${APIGEE_ORG}    data:metrics    access:read-only
    ${health_score}=    Evaluate    (${error_score} + ${latency_score} + ${anomaly_score} + ${target_score}) / 4
    ${health_score}=    Convert to Number    ${health_score}    2
    RW.Core.Add to Report    Apigee Traffic Health Score: ${health_score} -- error_rate: ${error_score}, latency: ${latency_score}, throughput: ${anomaly_score}, target: ${target_score}
    RW.Core.Push Metric    ${health_score}

*** Keywords ***
Suite Initialization
    ${gcp_credentials}=    RW.Core.Import Secret    gcp_credentials
    ...    type=string
    ...    description=GCP service account json used to authenticate with GCP APIs and Cloud Monitoring.
    ...    pattern=\w*
    ...    example={"type": "service_account","project_id":"myproject-ID", ... super secret stuff ...}
    ${APIGEE_ORG}=    RW.Core.Import User Variable    APIGEE_ORG
    ...    type=string
    ...    description=The Apigee organization name that scopes which proxies, environments, and target servers are evaluated.
    ...    pattern=\w*
    ...    example=my-apigee-org
    ${GCP_PROJECT_ID}=    RW.Core.Import User Variable    GCP_PROJECT_ID
    ...    type=string
    ...    description=The GCP Project ID that hosts the Apigee runtime and is the Cloud Monitoring scope for metric queries.
    ...    pattern=\w*
    ...    example=myproject-ID
    ${ERROR_RATE_THRESHOLD}=    RW.Core.Import User Variable    ERROR_RATE_THRESHOLD
    ...    type=string
    ...    description=Error/fault rate (percent) above which a proxy is flagged.
    ...    pattern=^\d*\.?\d+$
    ...    default=5
    ${LATENCY_MS_THRESHOLD}=    RW.Core.Import User Variable    LATENCY_MS_THRESHOLD
    ...    type=string
    ...    description=p95 latency in milliseconds above which a proxy is flagged as slow.
    ...    pattern=^\d+$
    ...    default=500
    ${METRIC_WINDOW_MIN}=    RW.Core.Import User Variable    METRIC_WINDOW_MIN
    ...    type=string
    ...    description=Lookback window in minutes for the Cloud Monitoring metric queries.
    ...    pattern=^\d+$
    ...    default=60
    Set Suite Variable    ${gcp_credentials}    ${gcp_credentials}
    Set Suite Variable    ${APIGEE_ORG}    ${APIGEE_ORG}
    Set Suite Variable    ${GCP_PROJECT_ID}    ${GCP_PROJECT_ID}
    Set Suite Variable    ${ERROR_RATE_THRESHOLD}    ${ERROR_RATE_THRESHOLD}
    Set Suite Variable    ${LATENCY_MS_THRESHOLD}    ${LATENCY_MS_THRESHOLD}
    Set Suite Variable    ${METRIC_WINDOW_MIN}    ${METRIC_WINDOW_MIN}
    ${OS_PATH}=    Get Environment Variable    PATH
    Set Suite Variable
    ...    ${env}
    ...    {"CLOUDSDK_CORE_PROJECT":"${GCP_PROJECT_ID}","PATH":"$PATH:${OS_PATH}","APIGEE_ORG":"${APIGEE_ORG}","GCP_PROJECT_ID":"${GCP_PROJECT_ID}","ERROR_RATE_THRESHOLD":"${ERROR_RATE_THRESHOLD}","LATENCY_MS_THRESHOLD":"${LATENCY_MS_THRESHOLD}","METRIC_WINDOW_MIN":"${METRIC_WINDOW_MIN}"}
    RW.CLI.Run CLI
    ...    cmd=gcloud auth activate-service-account --key-file="./${gcp_credentials.key}" || true
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
