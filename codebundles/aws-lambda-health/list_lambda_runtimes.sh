#!/bin/bash
auth() {
    # if required AWS_ cli vars are not set, error and exit 1
    if [[ -z $AWS_ACCESS_KEY_ID || -z $AWS_SECRET_ACCESS_KEY  || -z $AWS_REGION ]]; then
        echo "AWS credentials not set. Please set AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY environment variables."
        exit 1
    fi
    # if AWS_ROLE_ARN then assume the role using sts and override the pre-existing key ENVs
    if [[ -n $AWS_ROLE_ARN ]]; then
        sts_output=$(aws sts assume-role --role-arn "$AWS_ROLE_ARN" --role-session-name "AssumeRoleSession")
        AWS_ACCESS_KEY_ID=$(echo "$sts_output" | jq -r '.Credentials.AccessKeyId')
        AWS_SECRET_ACCESS_KEY=$(echo "$sts_output" | jq -r '.Credentials.SecretAccessKey')
        AWS_SESSION_TOKEN=$(echo "$sts_output" | jq -r '.Credentials.SessionToken')
        export AWS_ACCESS_KEY_ID
        export AWS_SECRET_ACCESS_KEY
        export AWS_SESSION_TOKEN
    fi
}
auth

# Fetch all Lambda function names
function_names=$(aws lambda list-functions --query 'Functions[*].FunctionName' --output text)

# Iterate over each function name
for function_name in $function_names; do
    # Fetch runtime and version for each function
    runtime=$(aws lambda get-function --function-name $function_name --query 'Configuration.Runtime' --output text)
    version=$(aws lambda get-function --function-name $function_name --query 'Configuration.Version' --output text)

    # Print function name, runtime, and version
    echo "Function Name: $function_name"
    echo "Runtime: $runtime"
    echo "Version: $version"
    echo "------------------------"
done