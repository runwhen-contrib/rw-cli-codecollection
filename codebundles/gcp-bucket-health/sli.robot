*** Settings ***
Documentation       Inspect GCP Storage bucket usage and configuration.
Metadata            Author    stewartshea
Metadata            Display Name    GCP Storage Bucket Health
Metadata            Supports    GCP,GCS

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             OperatingSystem

Suite Setup         Suite Initialization


*** Tasks ***
Fetch GCP Bucket Storage Utilization for `${PROJECT_IDS}`
    [Documentation]    Fetches all GCP buckets in each project and obtains the total size.
    [Tags]    gcloud    gcs    gcp    bucket
    ${bucket_usage}=    RW.CLI.Run Bash File
    ...    bash_file=bucket_size.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials_json=${gcp_credentials_json}
    ...    show_in_rwl_cheatsheet=true
    ...    timeout_seconds=240
    ${buckets_over_threshold}=    RW.CLI.Run Cli
    ...    cmd=cat $HOME/bucket_report.json | jq '[.[] | select(.size_tb > ${USAGE_THRESHOLD})] | length'
    ...    env=${env}
    ${buckets_over_utilization}=    Evaluate    1 if int(${buckets_over_threshold.stdout}) == 0 else 0
    Set Global Variable    ${buckets_over_utilization}

Check GCP Bucket Security Configuration for `${PROJECT_IDS}`
    [Documentation]    Fetches all GCP buckets in each project and checks for public buckets, risky IAM permissions, and encryption configuration.
    [Tags]    gcloud    gcs    gcp    bucket    security
    ${bucket_security_configuration}=    RW.CLI.Run Bash File
    ...    bash_file=check_security.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials_json=${gcp_credentials_json}
    ...    show_in_rwl_cheatsheet=true
    ${bucket_security_output}=    RW.CLI.Run Cli
    ...    cmd=cat $HOME/bucket_security_issues.json | jq . 
    ...    env=${env}
    ${total_public_access_buckets}=    RW.CLI.Run Cli
    ...    cmd=cat $HOME/bucket_security_issues.json | jq '[.[] | select(.issue_type == "public_access")] | length' 
    ...    env=${env}
    ${public_bucket_score}=    Evaluate    1 if int(${total_public_access_buckets.stdout}) <= ${PUBLIC_ACCESS_BUCKET_THRESHOLD} else 0
    Set Global Variable    ${public_bucket_score}

Generate Bucket Score
    ${bucket_health_score}=      Evaluate  (${buckets_over_utilization} + ${public_bucket_score}) / 2
    ${health_score}=      Convert to Number    ${bucket_health_score}  2
    RW.Core.Push Metric    ${health_score}

*** Keywords ***
Suite Initialization
    ${gcp_credentials_json}=    RW.Core.Import Secret    gcp_credentials_json
    ...    type=string
    ...    description=GCP service account json used to authenticate with GCP APIs.
    ...    pattern=\w*
    ...    example={"type": "service_account","project_id":"myproject-ID", ... super secret stuff ...}
    ${PROJECT_IDS}=    RW.Core.Import User Variable    PROJECT_IDS
    ...    type=string
    ...    description=The GCP Project ID to scope the API to. Accepts multiple comma separated project IDs.
    ...    pattern=\w*
    ...    example=myproject-ID
    ${USAGE_THRESHOLD}=    RW.Core.Import User Variable    USAGE_THRESHOLD
    ...    type=string
    ...    description=The amount of storage, in TB, to generate an issue on. 
    ...    pattern=\w*
    ...    example=0.5
    ...    default=00.5
    ${PUBLIC_ACCESS_BUCKET_THRESHOLD}=    RW.Core.Import User Variable    PUBLIC_ACCESS_BUCKET_THRESHOLD
    ...    type=string
    ...    description=The amount of storage buckets that can be publicly accessible. 
    ...    pattern=\w*
    ...    example=1
    ...    default=0
    ${HOME}=    Get Environment Variable    HOME
    ${OS_PATH}=    Get Environment Variable    PATH
    Set Suite Variable      ${USAGE_THRESHOLD}    ${USAGE_THRESHOLD}
    Set Suite Variable      ${PUBLIC_ACCESS_BUCKET_THRESHOLD}    ${PUBLIC_ACCESS_BUCKET_THRESHOLD}
    Set Suite Variable    ${PROJECT_IDS}    ${PROJECT_IDS}
    Set Suite Variable    ${gcp_credentials_json}    ${gcp_credentials_json}
    Set Suite Variable
    ...    ${env}
    ...    {"GOOGLE_APPLICATION_CREDENTIALS":"./${gcp_credentials_json.key}","PATH":"$PATH:${OS_PATH}", "PROJECT_IDS":"${PROJECT_IDS}", "HOME":"${HOME}"}
