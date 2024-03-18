#!/bin/bash

# Environment Variables:
# AWS_REGION

serverless_caches=$(aws elasticache describe-serverless-caches --region "$AWS_REGION" | jq -c '.ServerlessCaches[]')
if [[ -z $serverless_caches ]]; then
    echo "No serverless caches found."
    exit 0
fi
echo $serverless_caches | while read i; do
    echo $i
    arn=$(echo "$i" | jq -r '.ARN')
    cache_name=$(echo "$i" | jq -r '.ServerlessCacheName')
    status=$(echo "$i" | jq -r '.Status')
    port=$(echo "$i" | jq -r '.Port')
    version=$(echo "$i" | jq -r '.FullEngineVersion')
    endpoint=$(echo "$i" | jq -r '.Endpoint.Address')
    snapshot_limit=$(echo "$i" | jq -r '.SnapshotRetentionLimit')
    issue_snapshot_zero=""
    if [[ $snapshot_limit == "0" ]]; then
        issue_snapshot_zero="Error: Snapshot retention limit is set to 0"
    fi
    issue_status=""
    if [[ $status != "available" ]]; then
        issue_status="Error: Status is not available"
    fi

    echo "-------------------"
    echo "ARN: $arn"
    echo "Serverless Cache Name: $cache_name"
    echo "Status: $status"
    echo "Port: $port"
    echo "Version: $version"
    echo "Endpoint: $endpoint"
    echo "Snapshot Limit: $snapshot_limit"
    if [[ -n $issue_snapshot_zero ]]; then
        echo $issue_snapshot_zero
    fi
    if [[ -n $issue_status ]]; then
        echo $issue_status
    fi
    echo "-------------------"
    echo ""
done