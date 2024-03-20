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
# Verify AWS Lambda Function Configuration
#     [Documentation]   This script is used to verify the configuration of a specified AWS Lambda function. It retrieves and prints the function's configuration, policy, aliases, and versions. If any of these operations fail, the script will print an error message and exit with a status of 1. On successful completion, it prints a success message.
#     [Tags]  AWS    Lambda    Function Configuration    Verification    Script    Bash    AWS CLI    Function Policy    Function Aliases    Function Versions    Command Success    Command Failure    
#     ${process}=    Run Process    ${CURDIR}/verify_aws_lambda_function_config.sh    env=${env}
#     RW.Core.Add Pre To Report    ${process.stdout}

Analyze AWS Lambda Invocation Errors
    [Documentation]   This bash script is designed to analyze AWS Lambda Invocation Errors for a specified function within a specified region. It fetches the last 50 invocation errors from the AWS CloudWatch logs and prints them. If no errors are found, it prints a message stating that no invocation errors were found for the function. It requires AWS CLI and jq to be installed and properly configured.
    [Tags]  AWS    Lambda    Error Analysis    Invocation Errors    CloudWatch    Logs    Shell Script    Bash    Troubleshooting    Monitoring    Automation    AWS Region    Function Name    Log Streams    Log Events    
    ${process}=    Run Process    ${CURDIR}/analyze_lambda_invocation_errors.sh    env=${env}
    RW.Core.Add Pre To Report    ${process.stdout}

# Monitor AWS Lambda Performance Metrics
#     [Documentation]   This script is a bash utility for AWS Lambda functions. It retrieves and displays the details of a specified Lambda function, the last 100 log events, and various function metrics (Duration, Errors, Throttles, Invocations) for the past 24 hours in the AWS region 'us-west-2'. The function name and AWS region are defined as variables at the start of the script. This script requires AWS CLI and appropriate permissions to execute the commands.
#     [Tags]  AWS    Lambda    CloudWatch    Logs    Metrics    Bash    Scripting    Function Monitoring    Error Tracking    Throttling    Invocations    Duration    Command Line Interface    AWS CLI    us-west-2    myLambdaFunction    
#     ${process}=    Run Process    ${CURDIR}/monitor_aws_lambda_performance_metrics.sh    env=${env}
#     RW.Core.Add Pre To Report    ${process.stdout}

# Manage Lambda Concurrency Limits using AWS CLI
#     [Documentation]   This script is designed to modify and verify the concurrency limit of a specified AWS Lambda function. It first retrieves the current concurrency limit of the function, then sets a new limit and verifies if the new limit has been set correctly. If the new limit is set correctly, it outputs a success message; otherwise, it outputs a failure message. The function name and new concurrency limit are specified by the user through the FUNCTION_NAME and NEW_CONCURRENCY_LIMIT variables.
#     [Tags]  Lambda Function    Concurrency Limit    AWS CLI    Shell Script    Bash    AWS Lambda    Cloud Computing    Infrastructure Management    Automation    DevOps    
#     ${process}=    Run Process    ${CURDIR}/manage_lambda_concurrency_limits_awscli.sh    env=${env}
#     RW.Core.Add Pre To Report    ${process.stdout}

# Inspect IAM roles and resource access permissions for Lambda
#     [Documentation]   This script is designed to interact with AWS IAM and Lambda services to list IAM roles, retrieve the IAM role associated with a specified Lambda function, and get the policy attached to that role. It also obtains the policy document and lists the resources that the Lambda function has access to. The AWS region and the name of the Lambda function are defined as variables at the start of the script. The script uses AWS CLI commands and requires appropriate AWS credentials to be set up.
#     [Tags]  bash script    AWS    IAM roles    Lambda function    policy document    list resources    get-policy    get-function-configuration    list-roles    list-attached-role-policies    get-policy-version    scripting    automation    cloud computing    security    access management    
#     ${process}=    Run Process    ${CURDIR}/inspect_lambda_iam_roles_permissions.sh us-east-1 your_lambda_function_name    env=${env}
#     RW.Core.Add Pre To Report    ${process.stdout}

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