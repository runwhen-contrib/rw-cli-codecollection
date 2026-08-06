*** Settings ***
Documentation       Measures the health of BigQuery datasets by scoring table sizes, access configuration, expiration policies, audit logging, and table optimization. Produces a value between 0 (completely failing) and 1 (fully passing).
Metadata            Author    rw-codebundle-agent
Metadata            Display Name    GCP BigQuery Dataset Health
Metadata            Supports    GCP,BigQuery
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
    ${TABLE_SIZE_THRESHOLD_GB}=    RW.Core.Import User Variable    TABLE_SIZE_THRESHOLD_GB
    ...    type=string
    ...    description=Table size in GB above which an issue is raised.
    ...    pattern=\w*
    ...    default=100
    ${TABLE_GROWTH_THRESHOLD_PERCENT}=    RW.Core.Import User Variable    TABLE_GROWTH_THRESHOLD_PERCENT
    ...    type=string
    ...    description=Month-over-month growth percentage that triggers an alert.
    ...    pattern=\w*
    ...    default=50
    ${INCLUDE_STREAMING_BUFFER}=    RW.Core.Import User Variable    INCLUDE_STREAMING_BUFFER
    ...    type=string
    ...    description=Whether to include streaming buffer in table size calculations.
    ...    pattern=\w*
    ...    default=false
    ${OS_PATH}=    Get Environment Variable    PATH
    Set Suite Variable    ${GCP_PROJECT_ID}    ${GCP_PROJECT_ID}
    Set Suite Variable    ${TABLE_SIZE_THRESHOLD_GB}    ${TABLE_SIZE_THRESHOLD_GB}
    Set Suite Variable    ${INCLUDE_STREAMING_BUFFER}    ${INCLUDE_STREAMING_BUFFER}
    Set Suite Variable    ${gcp_credentials}    ${gcp_credentials}
    Set Suite Variable
    ...    ${env}
    ...    {"GOOGLE_APPLICATION_CREDENTIALS":"./${gcp_credentials.key}","PATH":"$PATH:${OS_PATH}","GCP_PROJECT_ID":"${GCP_PROJECT_ID}","TABLE_SIZE_THRESHOLD_GB":"${TABLE_SIZE_THRESHOLD_GB}","INCLUDE_STREAMING_BUFFER":"${INCLUDE_STREAMING_BUFFER}"}
    RW.CLI.Run CLI
    ...    cmd=gcloud auth activate-service-account --key-file="$GOOGLE_APPLICATION_CREDENTIALS" || true
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}


*** Tasks ***
Score BigQuery Table Size Trends for `${GCP_PROJECT_ID}`
    [Documentation]    Scores table sizes against the configured threshold. Returns 1 if no oversized tables, 0 otherwise.
    [Tags]    gcp    bigquery    dataset    data:metrics    access:read-only
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check_table_size_trends.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ${issues_output}=    RW.CLI.Run Cli
    ...    cmd=cat table_size_issues.json | jq length
    ...    env=${env}
    ${size_score}=    Evaluate    1 if int(${issues_output.stdout}) == 0 else 0
    Set Suite Variable    ${size_score}
    RW.Core.Push Metric    ${size_score}    sub_name=table_sizes

Score BigQuery Dataset Access Configuration for `${GCP_PROJECT_ID}`
    [Documentation]    Scores dataset access configuration. Returns 1 if no public or overly permissive access found.
    [Tags]    gcp    bigquery    dataset    security    data:config    access:read-only
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check_dataset_access.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ${issues_output}=    RW.CLI.Run Cli
    ...    cmd=cat dataset_access_issues.json | jq length
    ...    env=${env}
    ${access_score}=    Evaluate    1 if int(${issues_output.stdout}) == 0 else 0
    Set Suite Variable    ${access_score}
    RW.Core.Push Metric    ${access_score}    sub_name=access_config

Score BigQuery Table Expiration Policies for `${GCP_PROJECT_ID}`
    [Documentation]    Scores table expiration policy coverage. Returns 1 if no tables or datasets lack expiration.
    [Tags]    gcp    bigquery    dataset    retention    data:config    access:read-only
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check_table_expiration.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ${issues_output}=    RW.CLI.Run Cli
    ...    cmd=cat table_expiration_issues.json | jq length
    ...    env=${env}
    ${expiration_score}=    Evaluate    1 if int(${issues_output.stdout}) == 0 else 0
    Set Suite Variable    ${expiration_score}
    RW.Core.Push Metric    ${expiration_score}    sub_name=expiration_policies

Score BigQuery Audit Logging Configuration for `${GCP_PROJECT_ID}`
    [Documentation]    Scores audit logging configuration. Returns 1 if audit logging is properly configured.
    [Tags]    gcp    bigquery    logging    auditing    data:config    access:read-only
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check_audit_logging.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=120
    ${issues_output}=    RW.CLI.Run Cli
    ...    cmd=cat audit_logging_issues.json | jq length
    ...    env=${env}
    ${audit_score}=    Evaluate    1 if int(${issues_output.stdout}) == 0 else 0
    Set Suite Variable    ${audit_score}
    RW.Core.Push Metric    ${audit_score}    sub_name=audit_logging

Score BigQuery Table Optimization for `${GCP_PROJECT_ID}`
    [Documentation]    Scores table partitioning and clustering. Returns 1 if all large tables are properly optimized.
    [Tags]    gcp    bigquery    dataset    optimization    data:config    access:read-only
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check_table_optimization.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ${issues_output}=    RW.CLI.Run Cli
    ...    cmd=cat table_optimization_issues.json | jq length
    ...    env=${env}
    ${optimization_score}=    Evaluate    1 if int(${issues_output.stdout}) == 0 else 0
    Set Suite Variable    ${optimization_score}
    RW.Core.Push Metric    ${optimization_score}    sub_name=table_optimization

Generate Aggregate BigQuery Dataset Health Score for `${GCP_PROJECT_ID}`
    [Documentation]    Averages all sub-scores into a final 0-1 health score for the project.
    [Tags]    gcp    bigquery    dataset    health    data:metrics    access:read-only
    ${dataset_health_score}=    Evaluate    (${size_score} + ${access_score} + ${expiration_score} + ${audit_score} + ${optimization_score}) / 5
    ${health_score}=    Convert to Number    ${dataset_health_score}    2
    RW.Core.Add to Report    BigQuery Dataset Health Score: ${health_score}
    RW.Core.Push Metric    ${health_score}