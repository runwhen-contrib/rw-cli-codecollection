*** Settings ***
Documentation       Monitor AWS Lambda Invocation Errors
Metadata            Author    jon-funk
Metadata            Display Name    AWS Lambda Health Monitor
Metadata            Supports    AWS,AWS Lambda
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
Analyze AWS Lambda Invocation Errors
    [Documentation]   This bash script is designed to analyze AWS Lambda Invocation Errors for a specified function within a specified region. It fetches the last 50 invocation errors from the AWS CloudWatch logs and prints them. If no errors are found, it prints a message stating that no invocation errors were found for the function. It requires AWS CLI and jq to be installed and properly configured.
    [Tags]  AWS    Lambda    Error Analysis    Invocation Errors    CloudWatch    Logs 
    ${process}=    RW.CLI.Run Bash File    analyze_lambda_invocation_errors.sh
    ...    env=${env}
    ...    secret__AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID}
    ...    secret__AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY}
    IF    "ERROR" in """${process.stdout}"""
        RW.Core.Push Metric    0
    ELSE
        RW.Core.Push Metric    1
    END

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
