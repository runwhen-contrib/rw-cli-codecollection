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
    [Tags]  Amazon Web Services    AWS S3 
    ${process}=    RW.CLI.Run Bash File    check_aws_s3_bucket_storage_utilization.sh
    ...    env=${env}
    ...    secret__AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID}
    ...    secret__AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY}
    RW.Core.Add Pre To Report    ${process.stdout}

*** Keywords ***
Suite Initialization
    ${AWS_REGION}=    RW.Core.Import User Variable    AWS_REGION
    ...    type=string
    ...    description=AWS Region
    ...    pattern=\w*
    ${AWS_ACCESS_KEY_ID}=    RW.Core.Import Secret   AWS_ACCESS_KEY_ID
    ...    type=string
    ...    description=AWS Access Key ID
    ...    pattern=\w*
    ${AWS_SECRET_ACCESS_KEY}=    RW.Core.Import Secret   AWS_SECRET_ACCESS_KEY
    ...    type=string
    ...    description=AWS Secret Access Key
    ...    pattern=\w*

    Set Suite Variable    ${AWS_REGION}    ${AWS_REGION}
    Set Suite Variable    ${AWS_ACCESS_KEY_ID}    ${AWS_ACCESS_KEY_ID}
    Set Suite Variable    ${AWS_SECRET_ACCESS_KEY}    ${AWS_SECRET_ACCESS_KEY}

    Set Suite Variable
    ...    &{env}
    ...    AWS_REGION=${AWS_REGION}