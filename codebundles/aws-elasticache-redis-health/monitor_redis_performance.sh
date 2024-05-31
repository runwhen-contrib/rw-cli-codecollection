#!/bin/bash

# Environment Variables:
# AWS_REGION
# REDIS_PASSWORD
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

SLOWLOG_ENTRY_LIMIT="10"

# AWS CLI command to get the Redis instance details
redis_instances=$(aws elasticache describe-serverless-caches --region "$AWS_REGION" --query 'ServerlessCaches[*].[ServerlessCacheName, Endpoint.Address, Endpoint.Port]' --output text)

# Iterate over the Redis instances
while read -r cache_name endpoint_address port; do
    echo "Connecting to Redis instance: $cache_name"
    
    # Connect to the Redis instance
    redis-cli -h "$endpoint_address" -p "$port" -a "$REDIS_PASSWORD"

    # Monitor Redis Performance using INFO command
    echo "INFO command output:"
    redis-cli -h "$endpoint_address" -p "$port "-a "$REDIS_PASSWORD" INFO

    # Monitor Redis Performance using SLOWLOG command
    echo "SLOWLOG command output:"
    redis-cli -h "$endpoint_address" -p "$port" -a "$REDIS_PASSWORD" SLOWLOG GET $SLOWLOG_ENTRY_LIMIT

    echo "----------------------------------------"
done <<< "$redis_instances"
