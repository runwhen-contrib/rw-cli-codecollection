#!/bin/bash
source ./auth.sh

# Environment Variables:
# AWS_REGION

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

