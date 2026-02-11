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
    [Tags]  AWS    Lambda    Versions    Runtimes    access:read-only     data:config
    ${process}=    RW.CLI.Run Bash File    list_lambda_runtimes.sh
    ...    env=${env}
    ...    secret__AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID}
    ...    secret__AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY}
    ...    secret__AWS_ROLE_ARN=${AWS_ROLE_ARN}
    RW.Core.Add Pre To Report    ${process.stdout}

Analyze AWS Lambda Invocation Errors in Region `${AWS_REGION}`
    [Documentation]   This bash script is designed to analyze AWS Lambda Invocation Errors for a specified function within a specified region.
    [Tags]  AWS    Lambda    Error Analysis    Invocation Errors    CloudWatch    Logs    access:read-only    data:logs-regexp
    ${process}=    RW.CLI.Run Bash File    analyze_lambda_invocation_errors.sh
    ...    env=${env}
    ...    secret__AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID}
    ...    secret__AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY}
    ...    secret__AWS_ROLE_ARN=${AWS_ROLE_ARN}
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
    [Tags]  AWS    Lambda    CloudWatch    Logs    Metrics   access:read-only    data:config
    ${process}=    RW.CLI.Run Bash File    monitor_aws_lambda_performance_metrics.sh
    ...    env=${env}
    ...    secret__AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID}
    ...    secret__AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY}
    ...    secret__AWS_ROLE_ARN=${AWS_ROLE_ARN}
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
    ${AWS_ROLE_ARN}=    RW.Core.Import Secret   AWS_ROLE_ARN
    ...    type=string
    ...    description=AWS Role ARN
    ...    pattern=\w*

    Set Suite Variable    ${AWS_REGION}    ${AWS_REGION}
    Set Suite Variable    ${AWS_ACCESS_KEY_ID}    ${AWS_ACCESS_KEY_ID}
    Set Suite Variable    ${AWS_SECRET_ACCESS_KEY}    ${AWS_SECRET_ACCESS_KEY}
    Set Suite Variable    ${AWS_ROLE_ARN}    ${AWS_ROLE_ARN}

    Set Suite Variable
    ...    &{env}
    ...    AWS_REGION=${AWS_REGION}

