*** Settings ***
Documentation       
Metadata            Author    Placeholder
Metadata            Display Name    aws-lambda-failure-issue-investigation
Metadata            Supports    `AWS`, `AWS Lambda`, `Failure`, `Developer`, `Investigation`, `Service Disruption`, `Incident`, `Platform Issue`, `Troubleshooting`, `Resolution`, 
Metadata            Builder

Library             BuiltIn
Library             RW.Core
Library             RW.platform
Library             OperatingSystem
Library             String
Library             Process

Suite Setup         Suite Initialization

*** Tasks ***
List Lambda Versions and Runtimes
    [Documentation]   This script is designed to list all the versions and runtimes of a specified AWS Lambda function.
    [Tags]  AWS    Lambda    Metrics    Versions    Runtimes    List    Function   
    ${process}=    Run Process    ${CURDIR}/list_lambda_runtimes.sh    env=${env}
    RW.Core.Add Pre To Report    ${process.stdout}

Analyze AWS Lambda Invocation Errors
    [Documentation]   This bash script is designed to analyze AWS Lambda Invocation Errors for a specified function within a specified region. It fetches the last 50 invocation errors from the AWS CloudWatch logs and prints them. If no errors are found, it prints a message stating that no invocation errors were found for the function. It requires AWS CLI and jq to be installed and properly configured.
    [Tags]  AWS    Lambda    Error Analysis    Invocation Errors    CloudWatch    Logs    Shell Script    Bash    Troubleshooting    Monitoring    Automation    AWS Region    Function Name    Log Streams    Log Events    
    ${process}=    Run Process    ${CURDIR}/analyze_lambda_invocation_errors.sh    env=${env}
    RW.Core.Add Pre To Report    ${process.stdout}

Monitor AWS Lambda Performance Metrics
    [Documentation]   This script is a bash utility for AWS Lambda functions. It retrieves and displays the details of a specified Lambda function, the last 100 log events, and various function metrics (Duration, Errors, Throttles, Invocations) for the past 24 hours in the AWS region 'us-west-2'. The function name and AWS region are defined as variables at the start of the script. This script requires AWS CLI and appropriate permissions to execute the commands.
    [Tags]  AWS    Lambda    CloudWatch    Logs    Metrics    Bash    Scripting    Function Monitoring    Error Tracking    Throttling    Invocations    Duration    Command Line Interface    AWS CLI    us-west-2    myLambdaFunction    
    ${process}=    Run Process    ${CURDIR}/monitor_aws_lambda_performance_metrics.sh    env=${env}
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
    Set Suite Variable    ${AWS_ACCESS_KEY_ID}    ${AWS_ACCESS_KEY_ID.value}
    Set Suite Variable    ${AWS_SECRET_ACCESS_KEY}    ${AWS_SECRET_ACCESS_KEY.value}

    Set Suite Variable
    ...    &{env}
    ...    AWS_REGION=${AWS_REGION}
    ...    AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID}
    ...    AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY}