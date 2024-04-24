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

