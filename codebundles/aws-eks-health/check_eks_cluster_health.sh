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

# get list of eks clusters
eks_clusters=$(aws eks list-clusters --region $AWS_REGION --output json --query 'clusters[*]' | jq -r '.[]')
echo "----------------------------------"

echo "Checking EKS Fargate Clusters: $eks_clusters"

# get list of fargate profiles for each eks cluster
for cluster in $eks_clusters; do
    echo "----------------------------------"
    echo "Checking Cluster: $cluster"
    # eks
    cluster_info=$(aws eks describe-cluster --name "$cluster" --region $AWS_REGION --output json)
    # Get cluster status
    status=$(echo "$cluster_info" | jq -r '.cluster.status')
    # Get health issues
    health_issues=$(echo "$cluster_info" | jq '.cluster.health.issues')
    health_issues_count=$(echo "$health_issues" | jq '. | length')
    # Check if the cluster's status isn't ACTIVE or if there are health issues
    if [[ "$status" != "ACTIVE" ]] || [[ $health_issues_count > 0 ]]; then
        echo "Error: cluster $cluster has status $status and $health_issues_count health issues: $health_issues"
    fi
    echo "----------------------------------"

done
echo "----------------------------------"