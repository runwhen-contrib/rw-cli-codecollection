*** Settings ***
Documentation       Measures the health of GCP project quota by scoring allocation quota usage, rate quota consumption, quotas above threshold, and quota rejection events. Produces a value between 0 (completely failing) and 1 (fully passing).
Metadata            Author    rw-codebundle-agent
Metadata            Display Name    GCP Project Quota Health
Metadata            Supports    GCP,Project,Quota
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
    ...    description=GCP service account JSON key used to authenticate with GCP APIs.
    ...    pattern=\w*
    ...    example={"type": "service_account","project_id":"myproject-ID"}
    ${GCP_PROJECT_ID}=    RW.Core.Import User Variable    GCP_PROJECT_ID
    ...    type=string
    ...    description=GCP Project ID whose quotas are monitored.
    ...    pattern=\w*
    ...    example=my-gcp-project
    ${QUOTA_WARNING_THRESHOLD}=    RW.Core.Import User Variable    QUOTA_WARNING_THRESHOLD
    ...    type=string
    ...    description=Usage percentage of a quota limit that triggers an issue (0-100).
    ...    pattern=^\d+(\.\d+)?$
    ...    default=80
    ${LOOKBACK_MINUTES}=    RW.Core.Import User Variable    LOOKBACK_MINUTES
    ...    type=string
    ...    description=Lookback window (minutes) for rate quota metrics and Cloud Logging rejection events.
    ...    pattern=^\d+$
    ...    default=1440
    ${SERVICES}=    RW.Core.Import User Variable    SERVICES
    ...    type=string
    ...    description=Comma-separated service names to limit quota checks to; 'All' checks every enabled service.
    ...    pattern=\w*
    ...    default=All
    ${REJECTION_THRESHOLD}=    RW.Core.Import User Variable    REJECTION_THRESHOLD
    ...    type=string
    ...    description=Minimum number of quota rejection events in the lookback window that triggers an issue.
    ...    pattern=^\d+$
    ...    default=1
    ${OS_PATH}=    Get Environment Variable    PATH
    Set Suite Variable    ${GCP_PROJECT_ID}    ${GCP_PROJECT_ID}
    Set Suite Variable    ${QUOTA_WARNING_THRESHOLD}    ${QUOTA_WARNING_THRESHOLD}
    Set Suite Variable    ${LOOKBACK_MINUTES}    ${LOOKBACK_MINUTES}
    Set Suite Variable    ${SERVICES}    ${SERVICES}
    Set Suite Variable    ${REJECTION_THRESHOLD}    ${REJECTION_THRESHOLD}
    Set Suite Variable    ${gcp_credentials}    ${gcp_credentials}
    Set Suite Variable
    ...    ${env}
    ...    {"CLOUDSDK_BILLING_QUOTA_PROJECT":"${GCP_PROJECT_ID}","CLOUDSDK_CORE_PROJECT":"${GCP_PROJECT_ID}","PATH":"$PATH:${OS_PATH}","GCP_PROJECT_ID":"${GCP_PROJECT_ID}","QUOTA_WARNING_THRESHOLD":"${QUOTA_WARNING_THRESHOLD}","LOOKBACK_MINUTES":"${LOOKBACK_MINUTES}","SERVICES":"${SERVICES}","REJECTION_THRESHOLD":"${REJECTION_THRESHOLD}"}
    RW.CLI.Run CLI
    ...    cmd=gcloud auth activate-service-account --key-file="./${gcp_credentials.key}" || true
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}


*** Tasks ***
Score Allocation Quota Usage for `${GCP_PROJECT_ID}`
    [Documentation]    Scores allocation quota usage against limits. Returns 1 if no allocation quota is at or near its limit, 0 otherwise.
    [Tags]    gcp    project    quota    allocation    data:config    access:read-only
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check_allocation_quotas.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=240
    ${issues_output}=    RW.CLI.Run Cli
    ...    cmd=cat allocation_quota_issues.json | jq length
    ...    env=${env}
    ${allocation_score}=    Evaluate    1 if int(${issues_output.stdout}) == 0 else 0
    Set Suite Variable    ${allocation_score}
    RW.Core.Push Metric    ${allocation_score}    sub_name=allocation_quota

Score Rate Quota Consumption for `${GCP_PROJECT_ID}`
    [Documentation]    Scores rate quota consumption and throttling events. Returns 1 if no rate quota is over limit and no throttling detected, 0 otherwise.
    [Tags]    gcp    project    quota    rate    data:metrics    access:read-only
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check_rate_quotas.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=240
    ${issues_output}=    RW.CLI.Run Cli
    ...    cmd=cat rate_quota_issues.json | jq length
    ...    env=${env}
    ${rate_score}=    Evaluate    1 if int(${issues_output.stdout}) == 0 else 0
    Set Suite Variable    ${rate_score}
    RW.Core.Push Metric    ${rate_score}    sub_name=rate_quota

Score Quotas Above Warning Threshold for `${GCP_PROJECT_ID}`
    [Documentation]    Scores the number of quotas above the configured warning threshold. Returns 1 if no quota exceeds the threshold, 0 otherwise.
    [Tags]    gcp    project    quota    threshold    data:config    access:read-only
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=identify_quotas_above_threshold.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=240
    ${issues_output}=    RW.CLI.Run Cli
    ...    cmd=cat quota_threshold_issues.json | jq length
    ...    env=${env}
    ${threshold_score}=    Evaluate    1 if int(${issues_output.stdout}) == 0 else 0
    Set Suite Variable    ${threshold_score}
    RW.Core.Push Metric    ${threshold_score}    sub_name=threshold

Score Quota Rejection Events for `${GCP_PROJECT_ID}`
    [Documentation]    Scores quota rejection events in Cloud Logging. Returns 1 if rejection volume is below the configured threshold, 0 otherwise.
    [Tags]    gcp    project    quota    logging    data:logs    access:read-only
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=analyze_quota_rejections.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=240
    ${issues_output}=    RW.CLI.Run Cli
    ...    cmd=cat quota_rejection_issues.json | jq length
    ...    env=${env}
    ${rejection_score}=    Evaluate    1 if int(${issues_output.stdout}) == 0 else 0
    Set Suite Variable    ${rejection_score}
    RW.Core.Push Metric    ${rejection_score}    sub_name=rejection

Generate Aggregate Quota Health Score for `${GCP_PROJECT_ID}`
    [Documentation]    Averages all sub-scores into a final 0-1 health score for the project's quotas.
    [Tags]    gcp    project    quota    health    data:metrics    access:read-only
    ${quota_health_score}=    Evaluate    (${allocation_score} + ${rate_score} + ${threshold_score} + ${rejection_score}) / 4
    ${health_score}=    Convert to Number    ${quota_health_score}    2
    RW.Core.Add to Report    GCP Project Quota Health Score: ${health_score}
    RW.Core.Push Metric    ${health_score}
