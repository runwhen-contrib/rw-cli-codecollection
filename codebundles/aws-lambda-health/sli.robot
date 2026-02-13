*** Settings ***
Documentation       Monitor AWS Lambda Invocation Errors
Metadata            Author    jon-funk
Metadata            Display Name    AWS Lambda Health Monitor
Metadata            Supports    AWS,Lambda
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
Analyze AWS Lambda Invocation Errors in Region `${AWS_REGION}`
    [Documentation]   This bash script is designed to analyze AWS Lambda Invocation Errors for a specified function within a specified region.
    [Tags]  AWS    Lambda    Error Analysis    Invocation Errors    CloudWatch    Logs 
    ${process}=    RW.CLI.Run Bash File    analyze_lambda_invocation_errors.sh
    ...    env=${env}
    IF    "ERROR" in """${process.stdout}"""
        RW.Core.Push Metric    0    sub_name=invocation_errors
        RW.Core.Push Metric    0
    ELSE
        RW.Core.Push Metric    1    sub_name=invocation_errors
        RW.Core.Push Metric    1
    END

*** Keywords ***
Suite Initialization
    # AWS credentials are provided by the platform from the aws-auth block (runwhen-local).
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
