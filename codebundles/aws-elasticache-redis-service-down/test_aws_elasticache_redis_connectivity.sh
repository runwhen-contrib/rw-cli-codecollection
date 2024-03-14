#!/bin/bash

# Variables
AWS_REGION="us-west-2"
ELASTICACHE_CLUSTER_ID="my-redis-cluster"
ELASTICACHE_ENDPOINT=""
ELASTICACHE_PORT="6379"
REDIS_PASSWORD="my-redis-password"

# Get the endpoint for the ElastiCache Redis cluster
ELASTICACHE_ENDPOINT=$(aws elasticache describe-cache-clusters --cache-cluster-id $ELASTICACHE_CLUSTER_ID --region $AWS_REGION --show-cache-node-info | jq -r '.CacheClusters[0].CacheNodes[0].Endpoint.Address')

# Check if the ElastiCache endpoint was fetched successfully
if [ -z "$ELASTICACHE_ENDPOINT" ]; then
    echo "Failed to fetch ElastiCache endpoint. Please check your cluster ID and AWS region."
    exit 1
fi

# Test connectivity to the ElastiCache Redis cluster
echo "Testing connectivity to ElastiCache Redis cluster at $ELASTICACHE_ENDPOINT:$ELASTICACHE_PORT..."
redis-cli -h $ELASTICACHE_ENDPOINT -p $ELASTICACHE_PORT -a $REDIS_PASSWORD ping

if [ $? -eq 0 ]; then
    echo "Successfully connected to the ElastiCache Redis cluster."
else
    echo "Failed to connect to the ElastiCache Redis cluster. Please check your network connectivity and Redis password."
    exit 1
fi