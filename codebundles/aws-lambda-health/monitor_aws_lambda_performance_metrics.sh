#!/bin/bash

# Environment Variables:
# AWS_REGION
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

START=$(date -d "60 minutes ago" +%s)
END=$(date +%s)
PERIOD=3600

lambda_functions=$(aws lambda list-functions --region "$AWS_REGION" --query 'Functions[*].[FunctionName]' --output text)
for lambda in $lambda_functions; do
    lambda_names+=("$lambda")
done

echo ------------------------
echo "Found lambda functions: ${lambda_names[*]}"
echo "Checking metrics: Duration, Errors, Throttles, Invocations"
echo "For the last 60 minutes"
echo ------------------------

for lambda_name in "${lambda_names[@]}"; do
    echo "Function Name: $lambda_name"
    echo "------------------------"
    aws cloudwatch get-metric-statistics --namespace AWS/Lambda --metric-name Duration \
    --dimensions Name=FunctionName,Value="$lambda_name" --statistics Average \
    --start-time "$START" \
    --end-time "$END" --period "$PERIOD" --region "$AWS_REGION"

    aws cloudwatch get-metric-statistics --namespace AWS/Lambda --metric-name Errors \
    --dimensions Name=FunctionName,Value="$lambda_name" --statistics Sum \
    --start-time "$START" \
    --end-time "$END" --period "$PERIOD" --region "$AWS_REGION"

    aws cloudwatch get-metric-statistics --namespace AWS/Lambda --metric-name Throttles \
    --dimensions Name=FunctionName,Value="$lambda_name" --statistics Sum \
    --start-time "$START" \
    --end-time "$END" --period "$PERIOD" --region "$AWS_REGION"

    aws cloudwatch get-metric-statistics --namespace AWS/Lambda --metric-name Invocations \
    --dimensions Name=FunctionName,Value="$lambda_name" --statistics Sum \
    --start-time "$START" \
    --end-time "$END" --period "$PERIOD" --region "$AWS_REGION"
done