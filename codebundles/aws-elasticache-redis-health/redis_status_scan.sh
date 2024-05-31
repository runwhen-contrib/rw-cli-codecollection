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

# Variables
serverless_caches=$(aws elasticache describe-serverless-caches --region "$AWS_REGION")

# Check for Errors in describe-serverless-caches JSON
echo ""
echo "Scanning ElastiCaches..."
echo -----------------------------
serverless_caches=$(aws elasticache describe-serverless-caches --region "$AWS_REGION")
error_count=$(echo "$serverless_caches" | jq '.ServerlessCaches | map(select(.Status != "available")) | length')
echo "$serverless_caches" | jq -r '.ServerlessCaches[] | "\(.ServerlessCacheName):\(.Status)"'
if [[ $error_count -gt 0 ]]; then
    echo ""
    echo "Error: There are $error_count serverless cache clusters with non-available status."
    echo "Serverless Cache Clusters dump: $serverless_caches"
    exit 1
fi
exit 0