# aws-lambda-failure-issue-investigation CodeBundle
### Tags:`AWS`, `AWS Lambda`, `Failure`, `Developer`, `Investigation`, `Service Disruption`, `Incident`, `Platform Issue`, `Troubleshooting`, `Resolution`, 
## CodeBundle Objective:
This runbook provides a comprehensive guide to managing and troubleshooting AWS Lambda functions. It covers tasks such as verifying the configuration of Lambda functions, analyzing invocation errors, monitoring performance metrics, and managing concurrency limits using AWS CLI. Additionally, it provides steps to inspect IAM roles and resource access permissions for Lambda. This runbook is essential for maintaining optimal function and security of AWS Lambda services.

## CodeBundle Inputs:

export AWS_REGION="PLACEHOLDER"

export LAMBDA_FUNCTION_NAME="PLACEHOLDER"

export FUNCTION_NAME="PLACEHOLDER"

export NEW_CONCURRENCY_LIMIT="PLACEHOLDER"


## CodeBundle Tasks:
### `Verify AWS Lambda Function Configuration`
#### Tags:`AWS`, `Lambda`, `Function Configuration`, `Verification`, `Script`, `Bash`, `AWS CLI`, `Function Policy`, `Function Aliases`, `Function Versions`, `Command Success`, `Command Failure`, 
### Task Documentation:
This script is used to verify the configuration of a specified AWS Lambda function. It retrieves and prints the function's configuration, policy, aliases, and versions. If any of these operations fail, the script will print an error message and exit with a status of 1. On successful completion, it prints a success message.
#### Usage Example:
`./verify_aws_lambda_function_config.sh`

### `Analyze AWS Lambda Invocation Errors`
#### Tags:`AWS`, `Lambda`, `Error Analysis`, `Invocation Errors`, `CloudWatch`, `Logs`, `Shell Script`, `Bash`, `Troubleshooting`, `Monitoring`, `Automation`, `AWS Region`, `Function Name`, `Log Streams`, `Log Events`, 
### Task Documentation:
This bash script is designed to analyze AWS Lambda Invocation Errors for a specified function within a specified region. It fetches the last 50 invocation errors from the AWS CloudWatch logs and prints them. If no errors are found, it prints a message stating that no invocation errors were found for the function. It requires AWS CLI and jq to be installed and properly configured.
#### Usage Example:
`./analyze_lambda_invocation_errors.sh`

### `Monitor AWS Lambda Performance Metrics`
#### Tags:`AWS`, `Lambda`, `CloudWatch`, `Logs`, `Metrics`, `Bash`, `Scripting`, `Function Monitoring`, `Error Tracking`, `Throttling`, `Invocations`, `Duration`, `Command Line Interface`, `AWS CLI`, `us-west-2`, `myLambdaFunction`, 
### Task Documentation:
This script is a bash utility for AWS Lambda functions. It retrieves and displays the details of a specified Lambda function, the last 100 log events, and various function metrics (Duration, Errors, Throttles, Invocations) for the past 24 hours in the AWS region 'us-west-2'. The function name and AWS region are defined as variables at the start of the script. This script requires AWS CLI and appropriate permissions to execute the commands.
#### Usage Example:
`./monitor_aws_lambda_performance_metrics.sh`

### `Manage Lambda Concurrency Limits using AWS CLI`
#### Tags:`Lambda Function`, `Concurrency Limit`, `AWS CLI`, `Shell Script`, `Bash`, `AWS Lambda`, `Cloud Computing`, `Infrastructure Management`, `Automation`, `DevOps`, 
### Task Documentation:
This script is designed to modify and verify the concurrency limit of a specified AWS Lambda function. It first retrieves the current concurrency limit of the function, then sets a new limit and verifies if the new limit has been set correctly. If the new limit is set correctly, it outputs a success message; otherwise, it outputs a failure message. The function name and new concurrency limit are specified by the user through the FUNCTION_NAME and NEW_CONCURRENCY_LIMIT variables.
#### Usage Example:
`./manage_lambda_concurrency_limits_awscli.sh`

### `Inspect IAM roles and resource access permissions for Lambda`
#### Tags:`bash script`, `AWS`, `IAM roles`, `Lambda function`, `policy document`, `list resources`, `get-policy`, `get-function-configuration`, `list-roles`, `list-attached-role-policies`, `get-policy-version`, `scripting`, `automation`, `cloud computing`, `security`, `access management`, 
### Task Documentation:
This script is designed to interact with AWS IAM and Lambda services to list IAM roles, retrieve the IAM role associated with a specified Lambda function, and get the policy attached to that role. It also obtains the policy document and lists the resources that the Lambda function has access to. The AWS region and the name of the Lambda function are defined as variables at the start of the script. The script uses AWS CLI commands and requires appropriate AWS credentials to be set up.
#### Usage Example:
`./inspect_lambda_iam_roles_permissions.sh us-east-1 your_lambda_function_name`
