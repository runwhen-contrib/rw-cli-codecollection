#!/bin/bash

# Variables
AWS_REGION="us-west-2"
FUNCTION_NAME="myLambdaFunction"

# Get the function details
aws lambda get-function --function-name $FUNCTION_NAME --region $AWS_REGION

# Get the last 100 log events
aws logs get-log-events --log-group-name /aws/lambda/$FUNCTION_NAME --limit 100 --region $AWS_REGION

# Get function metrics for the last 24 hours
aws cloudwatch get-metric-statistics --namespace AWS/Lambda --metric-name Duration \
--dimensions Name=FunctionName,Value=$FUNCTION_NAME --statistics Average \
--start-time $(date -d "-24 hours" -u +"%Y-%m-%dT%H:%M:%SZ") \
--end-time $(date -u +"%Y-%m-%dT%H:%M:%SZ") --period 3600 --region $AWS_REGION

aws cloudwatch get-metric-statistics --namespace AWS/Lambda --metric-name Errors \
--dimensions Name=FunctionName,Value=$FUNCTION_NAME --statistics Sum \
--start-time $(date -d "-24 hours" -u +"%Y-%m-%dT%H:%M:%SZ") \
--end-time $(date -u +"%Y-%m-%dT%H:%M:%SZ") --period 3600 --region $AWS_REGION

aws cloudwatch get-metric-statistics --namespace AWS/Lambda --metric-name Throttles \
--dimensions Name=FunctionName,Value=$FUNCTION_NAME --statistics Sum \
--start-time $(date -d "-24 hours" -u +"%Y-%m-%dT%H:%M:%SZ") \
--end-time $(date -u +"%Y-%m-%dT%H:%M:%SZ") --period 3600 --region $AWS_REGION

aws cloudwatch get-metric-statistics --namespace AWS/Lambda --metric-name Invocations \
--dimensions Name=FunctionName,Value=$FUNCTION_NAME --statistics Sum \
--start-time $(date -d "-24 hours" -u +"%Y-%m-%dT%H:%M:%SZ") \
--end-time $(date -u +"%Y-%m-%dT%H:%M:%SZ") --period 3600 --region $AWS_REGION