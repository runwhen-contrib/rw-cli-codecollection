#!/bin/bash

# Variables
AWS_REGION="us-west-2"
REDIS_HOST="my-redis-host"
REDIS_PORT="6379"
REDIS_PASSWORD="my-redis-password"
SLOWLOG_ENTRY_LIMIT="10"

# AWS CLI command to get the Redis instance details
aws elasticache describe-cache-clusters --region $AWS_REGION

# Connect to the Redis instance
redis-cli -h $REDIS_HOST -p $REDIS_PORT -a $REDIS_PASSWORD

# Monitor Redis Performance using INFO command
echo "INFO command output:"
redis-cli -h $REDIS_HOST -p $REDIS_PORT -a $REDIS_PASSWORD INFO

# Monitor Redis Performance using SLOWLOG command
echo "SLOWLOG command output:"
redis-cli -h $REDIS_HOST -p $REDIS_PORT -a $REDIS_PASSWORD SLOWLOG GET $SLOWLOG_ENTRY_LIMIT