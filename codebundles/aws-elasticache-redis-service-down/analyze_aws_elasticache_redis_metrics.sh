#!/bin/bash

# Environment Variables:
# AWS_REGION
# ELASTICACHE_ID

# Variables
METRIC_NAMESPACE="AWS/ElastiCache"
START_TIME=`date -u -d '1 day ago' +%FT%TZ`
END_TIME=`date -u +%FT%TZ`
STATISTICS="Average"
PERIOD="3600"

# Analyze AWS Elasticache Redis Metrics
METRIC_NAME="CPUUtilization"
cloudwatch_results=$(aws cloudwatch get-metric-statistics --namespace $METRIC_NAMESPACE \
--metric-name $METRIC_NAME --start-time $START_TIME --end-time $END_TIME \
--period $PERIOD --statistics $STATISTICS --region $AWS_REGION \
--dimensions Name=CacheClusterId,Value=$ELASTICACHE_ID)
echo "CloudWatch $METRIC_NAMESPACE $METRIC_NAME Results:"
echo $cloudwatch_results

METRIC_NAME="CacheMisses"
cloudwatch_results=$(aws cloudwatch get-metric-statistics --namespace $METRIC_NAMESPACE \
--metric-name $METRIC_NAME --start-time $START_TIME --end-time $END_TIME \
--period $PERIOD --statistics $STATISTICS --region $AWS_REGION \
--dimensions Name=CacheClusterId,Value=$ELASTICACHE_ID)
echo "CloudWatch $METRIC_NAMESPACE $METRIC_NAME Results:"
echo $cloudwatch_results

# Check Redis Performance
events=$(aws elasticache describe-events --region $AWS_REGION)
event_count=$(echo "$events" | jq '.Events | length')
if [[ $event_count -gt 0 ]]; then
    echo "Warning: Redis events are present. Total events: $event_count"
    echo Events:
    echo $events
fi

# Check for Errors in describe-serverless-caches JSON
echo "ElastiCache Serverless State:"
serverless_caches=$(aws elasticache describe-serverless-caches --region $AWS_REGION)
error_count=$(echo "$serverless_caches" | jq '.ServerlessCaches | map(select(.Status != "available")) | length')
echo "Overview:"
echo "$serverless_caches" | jq -r '.ServerlessCaches[] | "\(.ServerlessCacheName):\(.Status)"'
if [[ $error_count -gt 0 ]]; then
    echo "Error: There are $error_count serverless cache clusters with non-available status."
    echo "Serverless Cache Clusters dump: $serverless_caches"
fi