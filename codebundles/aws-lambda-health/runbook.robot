*** Settings ***
Documentation       Scans for AWS Lambda invocation errors
Metadata            Author    jon-funk
Metadata            Display Name    AWS Lambda Health Check
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
List Lambda Versions and Runtimes in AWS Region `${AWS_REGION}`
    [Documentation]   This script is designed to list all the versions and runtimes of a specified AWS Lambda function.
    [Tags]  AWS    Lambda    Versions    Runtimes    access:read-only 
    ${process}=    RW.CLI.Run Bash File    list_lambda_runtimes.sh
    ...    env=${env}
    RW.Core.Add Pre To Report    ${process.stdout}

Analyze AWS Lambda Invocation Errors in Region `${AWS_REGION}`
    [Documentation]   This bash script is designed to analyze AWS Lambda Invocation Errors for a specified function within a specified region.
    [Tags]  AWS    Lambda    Error Analysis    Invocation Errors    CloudWatch    Logs    access:read-only
    ${process}=    RW.CLI.Run Bash File    analyze_lambda_invocation_errors.sh
    ...    env=${env}
    RW.Core.Add Pre To Report    ${process.stdout}
    IF    "ERROR" in """${process.stdout}"""
        RW.Core.Add Issue    title=AWS Lambda Invocation Errors
        ...    severity=2
        ...    next_steps=Fetch Lambda logs for exceptions.
        ...    expected=The Lambda function has no invocation errors.
        ...    actual=The Lambda function has invocation errors.
        ...    reproduce_hint=Run analyze_lambda_invocation_errors.sh
        ...    details=${process.stdout}
    END

Monitor AWS Lambda Performance Metrics in AWS Region `${AWS_REGION}`
    [Documentation]   This script is a bash utility for AWS Lambda functions the lists their notable metrics.
    [Tags]  AWS    Lambda    CloudWatch    Logs    Metrics   access:read-only
    ${process}=    RW.CLI.Run Bash File    monitor_aws_lambda_performance_metrics.sh
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
