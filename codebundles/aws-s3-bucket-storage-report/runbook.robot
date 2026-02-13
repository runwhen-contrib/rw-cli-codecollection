*** Settings ***
Documentation       Generates a report for S3 buckets in a AWS region
Metadata            Author    jon-funk
Metadata            Display Name    AWS S3 Bucket Info Report
Metadata            Supports    AWS,S3
Metadata            Builder

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             OperatingSystem
Library             String
Library             Process

Suite Setup         Suite Initialization

*** Tasks ***
Check AWS S3 Bucket Storage Utilization
    [Documentation]   This script checks and displays the storage utilization of a specified AWS S3 bucket. It uses the AWS CLI to list all objects in the bucket recursively, displaying the results in a human-readable format and providing a summary of the total storage used.
    [Tags]  Amazon Web Services    AWS S3     data:config
    ${process}=    RW.CLI.Run Bash File    check_aws_s3_bucket_storage_utilization.sh
    ...    env=${env}
    RW.Core.Add Pre To Report    ${process.stdout}

*** Keywords ***
Suite Initialization
    # AWS credentials are provided by the platform from the aws-auth block (runwhen-local);
    # the runtime uses aws_utils to set up the auth environment (IRSA, access key, assume role, etc.).
    ${AWS_REGION}=    RW.Core.Import User Variable    AWS_REGION
    ...    type=string
    ...    description=AWS Region
    ...    pattern=\w*
    ${aws_credentials}=    RW.Core.Import Secret    aws_credentials
    ...    type=string
    ...    description=AWS credentials from the workspace (from aws-auth block; e.g. aws:access_key@cli, aws:irsa@cli).
    ...    pattern=\w*

    Set Suite Variable    ${AWS_REGION}    ${AWS_REGION}
    Set Suite Variable    ${aws_credentials}    ${aws_credentials}

    Set Suite Variable
    ...    &{env}
    ...    AWS_REGION=${AWS_REGION}