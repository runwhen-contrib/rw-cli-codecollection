#!/bin/bash
source ./auth.sh
# Environment Variables:
# AWS_REGION
# REDIS_PASSWORD

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
