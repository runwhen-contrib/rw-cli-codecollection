*** Settings ***
Documentation       Scores GCP Cloud SQL performance health as a 0-1 value averaged across four dimensions: utilization, performance/noisiness, long-running queries, and storage headroom.
Metadata            Author    rw-codebundle-agent
Metadata            Display Name    GCP Cloud SQL Performance
Metadata            Supports    GCP,Cloud SQL,SQL,Performance
Force Tags          GCP    Cloud SQL    SQL    Performance

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             OperatingSystem

Suite Setup         Suite Initialization

*** Tasks ***
Score Cloud SQL Utilization Health in `${GCP_PROJECT_ID}`
    [Documentation]    Scores 1.0 if no Cloud SQL instances are over the CPU utilization threshold, 0.0 otherwise.
    [Tags]    gcloud    sql    monitoring    gcp    ${GCP_PROJECT_ID}    data:metrics    access:read-only
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=review_utilization.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=300
    ${issues_output}=    RW.CLI.Run Cli
    ...    cmd=jq length utilization_issues.json 2>/dev/null || echo 0
    ...    env=${env}
    ${utilization_score}=    Evaluate    1 if int(${issues_output.stdout}) == 0 else 0
    Set Suite Variable    ${utilization_score}
    RW.Core.Push Metric    ${issues_output.stdout}    sub_name=overutilized_instance_count
    RW.Core.Push Metric    ${utilization_score}    sub_name=utilization

Score Cloud SQL Performance Health in `${GCP_PROJECT_ID}`
    [Documentation]    Scores 1.0 if no Cloud SQL instances show throughput spikes or performance issues, 0.0 otherwise.
    [Tags]    gcloud    sql    monitoring    gcp    ${GCP_PROJECT_ID}    data:metrics    access:read-only
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=analyze_performance.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=300
    ${issues_output}=    RW.CLI.Run Cli
    ...    cmd=jq length performance_issues.json 2>/dev/null || echo 0
    ...    env=${env}
    ${performance_score}=    Evaluate    1 if int(${issues_output.stdout}) == 0 else 0
    Set Suite Variable    ${performance_score}
    RW.Core.Push Metric    ${issues_output.stdout}    sub_name=performance_issue_count
    RW.Core.Push Metric    ${performance_score}    sub_name=performance

Score Cloud SQL Long Running Query Health in `${GCP_PROJECT_ID}`
    [Documentation]    Scores 1.0 if no queries exceed LONG_QUERY_SECONDS, 0.0 otherwise.
    [Tags]    gcloud    sql    logging    gcp    ${GCP_PROJECT_ID}    data:logs-query    access:read-only
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=find_long_running_queries.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=300
    ${issues_output}=    RW.CLI.Run Cli
    ...    cmd=jq length long_query_issues.json 2>/dev/null || echo 0
    ...    env=${env}
    ${query_score}=    Evaluate    1 if int(${issues_output.stdout}) == 0 else 0
    Set Suite Variable    ${query_score}
    RW.Core.Push Metric    ${issues_output.stdout}    sub_name=long_query_count
    RW.Core.Push Metric    ${query_score}    sub_name=long_running_queries

Score Cloud SQL Storage Health in `${GCP_PROJECT_ID}`
    [Documentation]    Scores 1.0 if no Cloud SQL instances are at risk of running out of disk, 0.0 otherwise.
    [Tags]    gcloud    sql    monitoring    gcp    ${GCP_PROJECT_ID}    data:metrics-config    access:read-only
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check_storage_growth.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=300
    ${issues_output}=    RW.CLI.Run Cli
    ...    cmd=jq length storage_issues.json 2>/dev/null || echo 0
    ...    env=${env}
    ${storage_score}=    Evaluate    1 if int(${issues_output.stdout}) == 0 else 0
    Set Suite Variable    ${storage_score}
    RW.Core.Push Metric    ${issues_output.stdout}    sub_name=storage_risk_count
    RW.Core.Push Metric    ${storage_score}    sub_name=storage

Generate Aggregate Cloud SQL Performance Health Score for `${GCP_PROJECT_ID}`
    [Documentation]    Averages the four dimension sub-scores into the final 0-1 performance health score.
    [Tags]    gcloud    sql    gcp    ${GCP_PROJECT_ID}    data:metrics    access:read-only
    ${health_score}=    Evaluate    (${utilization_score} + ${performance_score} + ${query_score} + ${storage_score}) / 4
    ${health_score}=    Convert to Number    ${health_score}    2
    RW.Core.Add to Report    Cloud SQL Performance Health Score: ${health_score} -- utilization: ${utilization_score}, performance: ${performance_score}, queries: ${query_score}, storage: ${storage_score}
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
    ...    description=The GCP Project ID that hosts the Cloud SQL instances to check.
    ...    pattern=\w*
    ...    example=myproject-ID
    ${RESOURCES}=    RW.Core.Import User Variable    RESOURCES
    ...    type=string
    ...    description=Optional comma-separated list of Cloud SQL instance names to scope to. Defaults to 'All'.
    ...    pattern=\w*
    ...    default=All
    ${CPU_THRESHOLD_PERCENT}=    RW.Core.Import User Variable    CPU_THRESHOLD_PERCENT
    ...    type=string
    ...    description=CPU utilization percentage above which an instance is flagged as over-utilized.
    ...    pattern=^\d+$
    ...    default=80
    ${UTILIZATION_HOURS}=    RW.Core.Import User Variable    UTILIZATION_HOURS
    ...    type=string
    ...    description=Look-back window (hours) for utilization and performance metrics.
    ...    pattern=^\d+$
    ...    default=6
    ${LONG_QUERY_SECONDS}=    RW.Core.Import User Variable    LONG_QUERY_SECONDS
    ...    type=string
    ...    description=Query duration (seconds) above which a query is considered long-running.
    ...    pattern=^\d+$
    ...    default=300
    ${STORAGE_FILL_THRESHOLD_PERCENT}=    RW.Core.Import User Variable    STORAGE_FILL_THRESHOLD_PERCENT
    ...    type=string
    ...    description=Storage fill percentage above which an instance without automatic storage increase is flagged.
    ...    pattern=^\d+$
    ...    default=80
    Set Suite Variable    ${GCP_PROJECT_ID}    ${GCP_PROJECT_ID}
    Set Suite Variable    ${gcp_credentials}    ${gcp_credentials}
    Set Suite Variable    ${RESOURCES}    ${RESOURCES}
    Set Suite Variable    ${CPU_THRESHOLD_PERCENT}    ${CPU_THRESHOLD_PERCENT}
    Set Suite Variable    ${UTILIZATION_HOURS}    ${UTILIZATION_HOURS}
    Set Suite Variable    ${LONG_QUERY_SECONDS}    ${LONG_QUERY_SECONDS}
    Set Suite Variable    ${STORAGE_FILL_THRESHOLD_PERCENT}    ${STORAGE_FILL_THRESHOLD_PERCENT}
    ${OS_PATH}=    Get Environment Variable    PATH
    Set Suite Variable
    ...    ${env}
    ...    {"CLOUDSDK_CORE_PROJECT":"${GCP_PROJECT_ID}","PATH":"$PATH:${OS_PATH}","GCP_PROJECT_ID":"${GCP_PROJECT_ID}","RESOURCES":"${RESOURCES}","CPU_THRESHOLD_PERCENT":"${CPU_THRESHOLD_PERCENT}","UTILIZATION_HOURS":"${UTILIZATION_HOURS}","LONG_QUERY_SECONDS":"${LONG_QUERY_SECONDS}","STORAGE_FILL_THRESHOLD_PERCENT":"${STORAGE_FILL_THRESHOLD_PERCENT}"}
    RW.CLI.Run CLI
    ...    cmd=gcloud auth activate-service-account --key-file="./${gcp_credentials.key}" || true
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
