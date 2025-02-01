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

# Variables
# THRESHOLD=85

# Fetch a list of bucket names
bucket_names=$(aws s3api list-buckets --query "Buckets[].Name" --output text)

# Iterate over the bucket names
for bucket_name in $bucket_names; do
    # Check AWS S3 Bucket Storage Utilization
    usage=$(aws s3 ls s3://$bucket_name --recursive --human-readable --summarize | grep "Total Size")
    count=$(aws s3 ls s3://$bucket_name --recursive | wc -l)
    echo "$bucket_name      object count: $count        usage: $usage"
done


