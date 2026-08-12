*** Settings ***
Documentation       Measures the health of BigQuery quota and capacity by scoring slot utilization, storage quota, daily query count, and dataset/table limits. Produces a value between 0 (completely failing) and 1 (fully passing).
Metadata            Author    rw-codebundle-agent
Metadata            Display Name    GCP BigQuery Quota Health
Metadata            Supports    GCP,BigQuery,Quota
Suite Setup         Suite Initialization
Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             OperatingSystem
Library             Collections


*** Keywords ***
Suite Initialization
    ${gcp_credentials}=    RW.Core.Import Secret    gcp_credentials
    ...    type=string
    ...    description=GCP service account json used to authenticate with GCP APIs.
    ...    pattern=\w*
    ...    example={"type": "service_account","project_id":"myproject-ID"}
    ${GCP_PROJECT_ID}=    RW.Core.Import User Variable    GCP_PROJECT_ID
    ...    type=string
    ...    description=The GCP Project ID to scope the API to.
    ...    pattern=\w*
    ...    example=myproject-id
    ${SLOT_UTILIZATION_THRESHOLD}=    RW.Core.Import User Variable    SLOT_UTILIZATION_THRESHOLD
    ...    type=string
    ...    description=Slot utilization percentage that triggers an alert.
    ...    pattern=^\d+(\.\d+)?$
    ...    default=80
    ${STORAGE_QUOTA_THRESHOLD}=    RW.Core.Import User Variable    STORAGE_QUOTA_THRESHOLD
    ...    type=string
    ...    description=Storage usage percentage of quota that triggers an alert.
    ...    pattern=^\d+(\.\d+)?$
    ...    default=85
    ${DAILY_QUERY_THRESHOLD}=    RW.Core.Import User Variable    DAILY_QUERY_THRESHOLD
    ...    type=string
    ...    description=Daily query count percentage of limit that triggers an alert.
    ...    pattern=^\d+(\.\d+)?$
    ...    default=80
    ${DATASET_TABLE_THRESHOLD}=    RW.Core.Import User Variable    DATASET_TABLE_THRESHOLD
    ...    type=string
    ...    description=Dataset/table count percentage of max that triggers an alert.
    ...    pattern=^\d+(\.\d+)?$
    ...    default=80
    ${DAILY_QUERY_LIMIT}=    RW.Core.Import User Variable    DAILY_QUERY_LIMIT
    ...    type=string
    ...    description=Expected daily query ceiling (override default 100000).
    ...    pattern=^\d+$
    ...    default=100000
    ${BIGQUERY_STORAGE_QUOTA_BYTES}=    RW.Core.Import User Variable    BIGQUERY_STORAGE_QUOTA_BYTES
    ...    type=string
    ...    description=Project storage quota in bytes (override default 10 TB).
    ...    pattern=^\d+$
    ...    default=10995116277760
    ${OS_PATH}=    Get Environment Variable    PATH
    Set Suite Variable    ${GCP_PROJECT_ID}    ${GCP_PROJECT_ID}
    Set Suite Variable    ${SLOT_UTILIZATION_THRESHOLD}    ${SLOT_UTILIZATION_THRESHOLD}
    Set Suite Variable    ${STORAGE_QUOTA_THRESHOLD}    ${STORAGE_QUOTA_THRESHOLD}
    Set Suite Variable    ${DAILY_QUERY_THRESHOLD}    ${DAILY_QUERY_THRESHOLD}
    Set Suite Variable    ${DATASET_TABLE_THRESHOLD}    ${DATASET_TABLE_THRESHOLD}
    Set Suite Variable    ${DAILY_QUERY_LIMIT}    ${DAILY_QUERY_LIMIT}
    Set Suite Variable    ${BIGQUERY_STORAGE_QUOTA_BYTES}    ${BIGQUERY_STORAGE_QUOTA_BYTES}
    Set Suite Variable    ${gcp_credentials}    ${gcp_credentials}
    Set Suite Variable
    ...    ${env}
    ...    {"CLOUDSDK_BILLING_QUOTA_PROJECT":"${GCP_PROJECT_ID}","CLOUDSDK_CORE_PROJECT":"${GCP_PROJECT_ID}","PATH":"$PATH:${OS_PATH}","GCP_PROJECT_ID":"${GCP_PROJECT_ID}","SLOT_UTILIZATION_THRESHOLD":"${SLOT_UTILIZATION_THRESHOLD}","STORAGE_QUOTA_THRESHOLD":"${STORAGE_QUOTA_THRESHOLD}","DAILY_QUERY_THRESHOLD":"${DAILY_QUERY_THRESHOLD}","DATASET_TABLE_THRESHOLD":"${DATASET_TABLE_THRESHOLD}","DAILY_QUERY_LIMIT":"${DAILY_QUERY_LIMIT}","BIGQUERY_STORAGE_QUOTA_BYTES":"${BIGQUERY_STORAGE_QUOTA_BYTES}"}
    RW.CLI.Run CLI
    ...    cmd=gcloud auth activate-service-account --key-file="./${gcp_credentials.key}" || true
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}


*** Tasks ***
Score BigQuery Slot Utilization for `${GCP_PROJECT_ID}`
    [Documentation]    Scores slot utilization against the configured threshold. Returns 1 if utilization is acceptable, 0 otherwise.
    [Tags]    gcp    bigquery    quota    slots    data:metrics    access:read-only
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check_slot_utilization.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ${issues_output}=    RW.CLI.Run Cli
    ...    cmd=cat slot_utilization_issues.json | jq length
    ...    env=${env}
    ${slot_score}=    Evaluate    1 if int(${issues_output.stdout}) == 0 else 0
    Set Suite Variable    ${slot_score}
    RW.Core.Push Metric    ${slot_score}    sub_name=slot_utilization

Score BigQuery Storage Quota for `${GCP_PROJECT_ID}`
    [Documentation]    Scores storage usage against the project quota. Returns 1 if below threshold, 0 otherwise.
    [Tags]    gcp    bigquery    quota    storage    data:metrics    access:read-only
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check_storage_quota.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ${issues_output}=    RW.CLI.Run Cli
    ...    cmd=cat storage_quota_issues.json | jq length
    ...    env=${env}
    ${storage_score}=    Evaluate    1 if int(${issues_output.stdout}) == 0 else 0
    Set Suite Variable    ${storage_score}
    RW.Core.Push Metric    ${storage_score}    sub_name=storage_quota

Score BigQuery Daily Query Limit for `${GCP_PROJECT_ID}`
    [Documentation]    Scores the daily query count against the limit. Returns 1 if within threshold, 0 otherwise.
    [Tags]    gcp    bigquery    quota    queries    data:metrics    access:read-only
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check_query_daily_limit.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ${issues_output}=    RW.CLI.Run Cli
    ...    cmd=cat query_daily_limit_issues.json | jq length
    ...    env=${env}
    ${query_score}=    Evaluate    1 if int(${issues_output.stdout}) == 0 else 0
    Set Suite Variable    ${query_score}
    RW.Core.Push Metric    ${query_score}    sub_name=daily_query_limit

Score BigQuery Dataset and Table Limits for `${GCP_PROJECT_ID}`
    [Documentation]    Scores dataset and table counts against GCP limits. Returns 1 if within threshold, 0 otherwise.
    [Tags]    gcp    bigquery    quota    dataset    data:config    access:read-only
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check_dataset_table_limits.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ${issues_output}=    RW.CLI.Run Cli
    ...    cmd=cat dataset_table_limit_issues.json | jq length
    ...    env=${env}
    ${limit_score}=    Evaluate    1 if int(${issues_output.stdout}) == 0 else 0
    Set Suite Variable    ${limit_score}
    RW.Core.Push Metric    ${limit_score}    sub_name=dataset_table_limits

Generate Aggregate BigQuery Quota Health Score for `${GCP_PROJECT_ID}`
    [Documentation]    Averages all sub-scores into a final 0-1 health score for the project.
    [Tags]    gcp    bigquery    quota    health    data:metrics    access:read-only
    ${quota_health_score}=    Evaluate    (${slot_score} + ${storage_score} + ${query_score} + ${limit_score}) / 4
    ${health_score}=    Convert to Number    ${quota_health_score}    2
    RW.Core.Add to Report    BigQuery Quota Health Score: ${health_score}
    RW.Core.Push Metric    ${health_score}
