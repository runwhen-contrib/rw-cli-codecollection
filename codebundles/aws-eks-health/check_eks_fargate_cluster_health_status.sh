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
    # fargate
    fargate_profiles=$(aws eks list-fargate-profiles --region $AWS_REGION --cluster-name $cluster --output text --query 'fargateProfileNames[*]')
    # print status of each fargate profile
    for profile in $fargate_profiles; do
        fargate_profile_state=$(aws eks describe-fargate-profile --region $AWS_REGION --cluster-name $cluster --fargate-profile-name $profile --output json --query 'fargateProfile')
        # echo fargate_profile_state: $fargate_profile_state
        status=$(echo "$fargate_profile_state" | jq -r '.status')
        echo "---"
        echo "Fargate Profile: $profile"
        echo "Status: $status"
        if [[ $status != "ACTIVE" ]]; then
            echo "Error: Fargate Profile $profile has non-active status: $status."
        fi
    done
    echo "----------------------------------"

done
echo "----------------------------------"

