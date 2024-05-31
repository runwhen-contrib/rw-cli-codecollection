#!/bin/bash

# Environment Variables:
#AWS_REGION
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

SINCE="24h"

lambda_names=()
lambda_functions=$(aws lambda list-functions --region "$AWS_REGION" --query 'Functions[*].[FunctionName]' --output text)
for lambda in $lambda_functions; do
    lambda_names+=("$lambda")
done

err_lambdas=() # Empty array to store lambda names with errors
lambda_arns=() # Empty array to store lambda arns

echo "Found lambda functions: ${lambda_names[*]}"
# Loop through the lambda functions
for lambda_function in $lambda_functions; do
    lambda_arn=$(aws lambda list-functions --region "$AWS_REGION" | jq -r '.Functions[] | select(.FunctionName=="'$lambda_function'") | .FunctionArn')
    lambda_arns+=("$lambda_arn")
done
echo "Found lambda arns: ${lambda_arns[*]}"

for lambda_name in "${lambda_names[@]}"; do
    # logstream=$(aws logs describe-log-streams --log-group-name /aws/lambda/"$lambda_name" --region "$AWS_REGION" | jq -r '.logStreams[-1] | .logStreamName')
    log_messages=$(aws logs tail /aws/lambda/"$lambda_name" --since $SINCE --region "$AWS_REGION")
    # log_messages=$(aws logs get-log-events --log-group-name /aws/lambda/"$lambda_name" --log-stream-name "$logstream" --start-time "$HOURS_IN_PAST" --query events[].message --output text)
    if [[ $log_messages == *"ERROR"* ]]; then
        err_lambdas+=("----------------------------------\n$lambda_name contains error:\n\n$log_messages\n\n")
    fi
done
echo -e "${err_lambdas[@]}"
echo "----------------------------------"