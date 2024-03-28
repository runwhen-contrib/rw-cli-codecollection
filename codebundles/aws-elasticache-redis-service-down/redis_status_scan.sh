#!/bin/bash
source ./auth.sh

# Environment Variables:
# AWS_REGION

# Variables
serverless_caches=$(aws elasticache describe-serverless-caches --region "$AWS_REGION")

# Check for Errors in describe-serverless-caches JSON
echo ""
echo "Scanning ElastiCaches..."
echo -----------------------------
serverless_caches=$(aws elasticache describe-serverless-caches --region "$AWS_REGION")
error_count=$(echo "$serverless_caches" | jq '.ServerlessCaches | map(select(.Status != "available")) | length')
echo "$serverless_caches" | jq -r '.ServerlessCaches[] | "\(.ServerlessCacheName):\(.Status)"'
if [[ $error_count -gt 0 ]]; then
    echo ""
    echo "Error: There are $error_count serverless cache clusters with non-available status."
    echo "Serverless Cache Clusters dump: $serverless_caches"
    exit 1
fi
exit 0