#!/bin/bash

# Variables
AWS_REGION="us-west-2"
ELASTICACHE_CLUSTER_ID="my-redis-cluster"

# Get the configuration endpoint
CONFIG_ENDPOINT=$(aws elasticache describe-cache-clusters --cache-cluster-id $ELASTICACHE_CLUSTER_ID --region $AWS_REGION --show-cache-node-info --query "CacheClusters[0].CacheNodes[0].Endpoint.Address" --output text)

# Get the port
PORT=$(aws elasticache describe-cache-clusters --cache-cluster-id $ELASTICACHE_CLUSTER_ID --region $AWS_REGION --show-cache-node-info --query "CacheClusters[0].CacheNodes[0].Endpoint.Port" --output text)

# Get the replication group ID
REPL_GROUP_ID=$(aws elasticache describe-cache-clusters --cache-cluster-id $ELASTICACHE_CLUSTER_ID --region $AWS_REGION --query "CacheClusters[0].ReplicationGroupId" --output text)

# Get the number of replicas
NUM_REPLICAS=$(aws elasticache describe-replication-groups --replication-group-id $REPL_GROUP_ID --region $AWS_REGION --query "ReplicationGroups[0].NodeGroups[0].NodeGroupMembers" --output text | wc -l)

# Get the engine version
ENGINE_VERSION=$(aws elasticache describe-cache-clusters --cache-cluster-id $ELASTICACHE_CLUSTER_ID --region $AWS_REGION --query "CacheClusters[0].EngineVersion" --output text)

# Get the parameter group
PARAM_GROUP=$(aws elasticache describe-cache-clusters --cache-cluster-id $ELASTICACHE_CLUSTER_ID --region $AWS_REGION --query "CacheClusters[0].CacheParameterGroup.CacheParameterGroupName" --output text)

# Get the security groups
SECURITY_GROUPS=$(aws elasticache describe-cache-clusters --cache-cluster-id $ELASTICACHE_CLUSTER_ID --region $AWS_REGION --query "CacheClusters[0].SecurityGroups[*].SecurityGroupId" --output text)

# Output the configuration
echo "Configuration Endpoint: $CONFIG_ENDPOINT"
echo "Port: $PORT"
echo "Replication Group ID: $REPL_GROUP_ID"
echo "Number of Replicas: $NUM_REPLICAS"
echo "Engine Version: $ENGINE_VERSION"
echo "Parameter Group: $PARAM_GROUP"
echo "Security Groups: $SECURITY_GROUPS"
