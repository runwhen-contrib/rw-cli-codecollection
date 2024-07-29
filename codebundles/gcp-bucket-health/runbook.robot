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
    ${bucket_output}=    RW.CLI.Run Cli
    ...    cmd=cat $HOME/bucket_report.json | jq .
    ...    env=${env}
    ${bucket_list}=    Evaluate    json.loads(r'''${bucket_output.stdout}''')    json
    FOR    ${item}    IN    @{bucket_list}
        IF    ${item["size_tb"]} > ${USAGE_THRESHOLD}
            RW.Core.Add Issue
            ...    severity=3
            ...    expected=Storage bucket should be below utilization threshold.
            ...    actual=Storage bucket is above utilization threshold.
            ...    title= GCP storage bucket `${item["bucket"]}` in project `${item["project"]}` is above utilization threshold.
            ...    reproduce_hint=${bucket_usage.cmd}
            ...    details=${item}
            ...    next_steps=Review Lifecycle configuration for GCP storage bucket `${item["bucket"]}` in project `${item["project"]}`
        END
    END
    RW.Core.Add Pre To Report    GCP Bucket Usage:\n${bucket_usage.stdout}
    RW.Core.Add Pre To Report    Commands Used:\n${bucket_usage.cmd}

Add GCP Bucket Storage Configuration for `${PROJECT_IDS}` to Report
    [Documentation]    Fetches all GCP buckets in each project and obtains the total size.
    [Tags]    gcloud    gcs    gcp    bucket
    ${bucket_configuration}=    RW.CLI.Run Bash File
    ...    bash_file=bucket_details.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials_json=${gcp_credentials_json}
    ...    show_in_rwl_cheatsheet=true
    RW.Core.Add Pre To Report    GCP Bucket Configuration:\n${bucket_configuration.stdout}
    RW.Core.Add Pre To Report    Commands Used:\n${bucket_configuration.cmd}

Check GCP Bucket Security Configuration for `${PROJECT_IDS}`
    [Documentation]    Fetches all GCP buckets in each project and checks for public buckets, risky IAM permissions, and encryption configuration.
    [Tags]    gcloud    gcs    gcp    bucket    security
    ${bucket_security_configuration}=    RW.CLI.Run Bash File
    ...    bash_file=check_security.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials_json=${gcp_credentials_json}
    ...    show_in_rwl_cheatsheet=true
    RW.Core.Add Pre To Report    GCP Security Configuration Check:\n${bucket_security_configuration.stdout}
    RW.Core.Add Pre To Report    Commands Used:\n${bucket_security_configuration.cmd}

    ${bucket_security_output}=    RW.CLI.Run Cli
    ...    cmd=cat $HOME/bucket_security_issues.json | jq .
    ...    env=${env}
    ${total_public_access_buckets}=    RW.CLI.Run Cli
    ...    cmd=cat $HOME/bucket_security_issues.json | jq '[.[] | select(.issue_type == "public_access")]'
    ...    env=${env}
    ${total_public_access_buckets_list}=    Evaluate
    ...    json.loads(r'''${total_public_access_buckets.stdout}''')
    ...    json
    IF    len(@{total_public_access_buckets_list}) > ${PUBLIC_ACCESS_BUCKET_THRESHOLD}
        FOR    ${item}    IN    @{total_public_access_buckets_list}
            RW.Core.Add Issue
            ...    severity=2
            ...    expected=Storage bucket should not have public access enabled.
            ...    actual=Storage bucket has public access enabled.
            ...    title= GCP storage bucket `${item["bucket"]}` in project `${item["project"]}` is accessible to the public.
            ...    reproduce_hint=${bucket_security_configuration.cmd}
            ...    details=${item}
            ...    next_steps=Review IAM configuration for GCP storage bucket `${item["bucket"]}` in project `${item["project"]}`
        END
    END

Fetch GCP Bucket Storage Operations Rate for `${PROJECT_IDS}`
    [Documentation]    Fetches all GCP buckets in each project and obtains the read and write operations rate that incurrs cost. Generates issues if the rate is above a specified threshold. 
    [Tags]    gcloud    gcs    gcp    bucket
    ${bucket_ops}=    RW.CLI.Run Bash File
    ...    bash_file=bucket_ops_costs.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials_json=${gcp_credentials_json}
    ...    show_in_rwl_cheatsheet=true
    ...    timeout_seconds=240
    ${bucket_ops_output}=    RW.CLI.Run Cli
    ...    cmd=cat $HOME/bucket_ops_report.json | jq .
    ...    env=${env}
    ${bucket_list}=    Evaluate    json.loads(r'''${bucket_ops_output.stdout}''')    json
    FOR    ${item}    IN    @{bucket_list}
        IF    ${item["total_ops"]} > ${OPS_RATE_THRESHOLD}
            RW.Core.Add Issue
            ...    severity=3
            ...    expected=Storage bucket should be below operations rate threshold.
            ...    actual=Storage bucket is above operations rate threshold.
            ...    title= GCP storage bucket `${item["bucket"]}` in project `${item["project"]}` has a rate of `${item["total_ops"]}` read/write operations per second.
            ...    reproduce_hint=${bucket_ops.cmd}
            ...    details=${item}
            ...    next_steps=Investigate storage operations for GCP storage bucket `${item["bucket"]}` in project `${item["project"]}` to avoid unnecessary cloud provider costs. 
        END
    END
    RW.Core.Add Pre To Report    GCP Bucket Usage:\n${bucket_ops_output.stdout}
    RW.Core.Add Pre To Report    Commands Used:\n${bucket_ops.cmd}

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
    ...    default=0.5
    ${OPS_RATE_THRESHOLD}=    RW.Core.Import User Variable    OPS_RATE_THRESHOLD
    ...    type=string
    ...    description=The rate of read+write operations, in ops/s, to generate an issue on.
    ...    pattern=\w*
    ...    example=10
    ...    default=10
    ${PUBLIC_ACCESS_BUCKET_THRESHOLD}=    RW.Core.Import User Variable    PUBLIC_ACCESS_BUCKET_THRESHOLD
    ...    type=string
    ...    description=The amount of storage buckets that can be publicly accessible.
    ...    pattern=\w*
    ...    example=1
    ...    default=0
    ${HOME}=    Get Environment Variable    HOME
    ${OS_PATH}=    Get Environment Variable    PATH
    Set Suite Variable    ${USAGE_THRESHOLD}    ${USAGE_THRESHOLD}
    Set Suite Variable    ${OPS_RATE_THRESHOLD}    ${OPS_RATE_THRESHOLD}
    Set Suite Variable    ${PUBLIC_ACCESS_BUCKET_THRESHOLD}    ${PUBLIC_ACCESS_BUCKET_THRESHOLD}
    Set Suite Variable    ${PROJECT_IDS}    ${PROJECT_IDS}
    Set Suite Variable    ${gcp_credentials_json}    ${gcp_credentials_json}
    Set Suite Variable
    ...    ${env}
    ...    {"GOOGLE_APPLICATION_CREDENTIALS":"./${gcp_credentials_json.key}","PATH":"$PATH:${OS_PATH}", "PROJECT_IDS":"${PROJECT_IDS}", "HOME":"${HOME}"}
