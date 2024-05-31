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

METRICS_LIST="vCPU Memory CPUUtilization Duration OnDemand Spot"
START=$(date -d "1 day ago" +%s)
END=$(date +%s)
PERIOD=3600


# Get a list of EKS clusters in the region
eks_clusters=$(aws eks list-clusters --region $AWS_REGION --output json | jq -r '.clusters[]')
echo "----------------------------------"
# Iterate over each EKS cluster
for cluster in $eks_clusters; do
    echo "Cluster: $cluster"
    # Get the Fargate profiles in use for the cluster
    for metric_name in $METRICS_LIST; do
        cloudwatch_results=$(aws cloudwatch get-metric-statistics \
            --region "$AWS_REGION" \
            --namespace AWS/Usage \
            --metric-name "$metric_name" \
            --start-time "$START" \
            --end-time "$END" \
            --period $PERIOD \
            --statistics Maximum \
            --dimensions Name=Service,Value="Fargate")
        newest_data=$(echo "$cloudwatch_results" | jq -r '.Datapoints | sort_by(.Timestamp) | last')
        echo "$metric_name: $newest_data"
    done
    echo "----------------------------------"
done
