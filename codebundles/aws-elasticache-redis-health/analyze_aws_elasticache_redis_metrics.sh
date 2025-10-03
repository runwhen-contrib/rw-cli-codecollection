#!/bin/bash

# Environment Variables:
# AWS_REGION
# Function to extract timestamp from log line, fallback to current time
extract_log_timestamp() {
    local log_line="$1"
    local fallback_timestamp=$(date -u +"%Y-%m-%dT%H:%M:%S.%3NZ")
    
    if [[ -z "$log_line" ]]; then
        echo "$fallback_timestamp"
        return
    fi
    
    # Try to extract common timestamp patterns
    # ISO 8601 format: 2024-01-15T10:30:45.123Z
    if [[ "$log_line" =~ ([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]{3})?Z?) ]]; then
        echo "${BASH_REMATCH[1]}"
        return
    fi
    
    # Standard log format: 2024-01-15 10:30:45
    if [[ "$log_line" =~ ([0-9]{4}-[0-9]{2}-[0-9]{2}[[:space:]]+[0-9]{2}:[0-9]{2}:[0-9]{2}) ]]; then
        # Convert to ISO format
        local extracted_time="${BASH_REMATCH[1]}"
        local iso_time=$(date -d "$extracted_time" -u +"%Y-%m-%dT%H:%M:%S.000Z" 2>/dev/null)
        if [[ $? -eq 0 ]]; then
            echo "$iso_time"
        else
            echo "$fallback_timestamp"
        fi
        return
    fi
    
    # DD-MM-YYYY HH:MM:SS format
    if [[ "$log_line" =~ ([0-9]{2}-[0-9]{2}-[0-9]{4}[[:space:]]+[0-9]{2}:[0-9]{2}:[0-9]{2}) ]]; then
        local extracted_time="${BASH_REMATCH[1]}"
        # Convert DD-MM-YYYY to YYYY-MM-DD for date parsing
        local day=$(echo "$extracted_time" | cut -d' ' -f1 | cut -d'-' -f1)
        local month=$(echo "$extracted_time" | cut -d' ' -f1 | cut -d'-' -f2)
        local year=$(echo "$extracted_time" | cut -d' ' -f1 | cut -d'-' -f3)
        local time_part=$(echo "$extracted_time" | cut -d' ' -f2)
        local iso_time=$(date -d "$year-$month-$day $time_part" -u +"%Y-%m-%dT%H:%M:%S.000Z" 2>/dev/null)
        if [[ $? -eq 0 ]]; then
            echo "$iso_time"
        else
            echo "$fallback_timestamp"
        fi
        return
    fi
    
    # Fallback to current timestamp
    echo "$fallback_timestamp"
}

auth() {
    # if required AWS_ cli vars are not set, error and exit 1
    if [[ -z $AWS_ACCESS_KEY_ID || -z $AWS_SECRET_ACCESS_KEY  || -z $AWS_REGION ]]; then
        echo "AWS credentials not set. Please set AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY environment variables."
        exit 1
    fi
    # if AWS_ROLE_ARN then assume the role using sts and override the pre-existing key ENVs
    if [[ -n $AWS_ROLE_ARN ]]; then
        sts_output=$(aws sts assume-role --role-arn "$AWS_ROLE_ARN" --role-session-name "AssumeRoleSession")
        AWS_ACCESS_KEY_ID=$(echo "$sts_output" | jq -r '.Credentials.AccessKeyId')
        AWS_SECRET_ACCESS_KEY=$(echo "$sts_output" | jq -r '.Credentials.SecretAccessKey')
        AWS_SESSION_TOKEN=$(echo "$sts_output" | jq -r '.Credentials.SessionToken')
        export AWS_ACCESS_KEY_ID
        export AWS_SECRET_ACCESS_KEY
        export AWS_SESSION_TOKEN
    fi
}
auth

# Variables
METRIC_NAMESPACE="AWS/ElastiCache"
START_TIME=$(date -u -d '1 day ago' +%FT%TZ)
END_TIME=$(date -u +%FT%TZ)
STATISTICS="Average"
PERIOD="3600"

# Analyze AWS Elasticache Redis Metrics
echo ""
echo "CloudWatch Metrics for ElastiCache Redis"
echo -----------------------------
METRIC_NAME="CPUUtilization"
cloudwatch_results=$(aws cloudwatch get-metric-statistics --namespace "$METRIC_NAMESPACE" \
--metric-name $METRIC_NAME --start-time "$START_TIME" --end-time "$END_TIME" \
--period $PERIOD --statistics $STATISTICS --region "$AWS_REGION")
echo "CloudWatch $METRIC_NAMESPACE $METRIC_NAME Results:"
echo "$cloudwatch_results"

METRIC_NAME="CacheMisses"
cloudwatch_results=$(aws cloudwatch get-metric-statistics --namespace $METRIC_NAMESPACE \
--metric-name $METRIC_NAME --start-time "$START_TIME" --end-time "$END_TIME" \
--period $PERIOD --statistics $STATISTICS --region "$AWS_REGION")
echo ""
echo "CloudWatch $METRIC_NAMESPACE $METRIC_NAME Results:"
echo "$cloudwatch_results"

# Check Redis Performance
events=$(aws elasticache describe-events --region $AWS_REGION)
event_count=$(echo "$events" | jq '.Events | length')
if [[ $event_count -gt 0 ]]; then
    echo ""
    echo -----------------------------        timestamp=$(date -u +"%Y-%m-%dT%H:%M:%S.%3NZ")

    # Extract timestamp from log context


    log_timestamp=$(extract_log_timestamp "$0")


    echo "Error: Redis events are present. Total events: $event_count (detected at $log_timestamp)"
    echo Events:
    echo "$events"
fi

# Check for Errors in describe-serverless-caches JSON
echo ""
echo "ElastiCache Serverless State:"
echo -----------------------------
serverless_caches=$(aws elasticache describe-serverless-caches --region "$AWS_REGION")
error_count=$(echo "$serverless_caches" | jq '.ServerlessCaches | map(select(.Status != "available")) | length')
echo "$serverless_caches" | jq -r '.ServerlessCaches[] | "\(.ServerlessCacheName):\(.Status)"'
if [[ $error_count -gt 0 ]]; then
    echo ""        timestamp=$(date -u +"%Y-%m-%dT%H:%M:%S.%3NZ")

    # Extract timestamp from log context


    log_timestamp=$(extract_log_timestamp "$0")


    echo "Error: There are $error_count serverless cache clusters with non-available status. (detected at $log_timestamp)"
    echo "Serverless Cache Clusters dump: $serverless_caches"
fi