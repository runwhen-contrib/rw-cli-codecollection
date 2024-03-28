#!/bin/bash
source ./auth.sh

# Environment Variables:
# AWS_REGION
METRICS_LIST="vCPU Memory CPUUtilization Duration OnDemand"
START=$(date -d "1 day ago" +%s)
END=$(date +%s)
PERIOD=600


# Get a list of EKS clusters in the region
eks_clusters=$(aws eks list-clusters --region $AWS_REGION --output json | jq -r '.clusters[]')
echo "----------------------------------"
# Iterate over each EKS cluster
for cluster in $eks_clusters; do
    echo "Cluster: $cluster"
    # Get the Fargate profiles in use for the cluster
    # fargate_profiles=$(aws eks describe-fargate-profiles --region $AWS_REGION --cluster-name $cluster --output text --query 'fargateProfileNames[*]')
    for metric_name in $METRICS_LIST; do
        cloudwatch_results=$(aws cloudwatch get-metric-statistics \
            --region "$AWS_REGION" \
            --namespace AWS/EKS/Fargate \
            --metric-name "$metric_name" \
            --start-time "$START" \
            --end-time "$END" \
            --period $PERIOD \
            --statistics Maximum \
            --dimensions Name=ClusterName,Value="$cluster")
        newest_data=$(echo "$cloudwatch_results" | jq -r '.Datapoints | sort_by(.Timestamp) | last')
        echo "$metric_name: $newest_data"
    done
    echo "----------------------------------"
done
