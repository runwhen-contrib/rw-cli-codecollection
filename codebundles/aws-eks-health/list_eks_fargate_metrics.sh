#!/bin/bash
source ./auth.sh

# Environment Variables:
# AWS_REGION
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
