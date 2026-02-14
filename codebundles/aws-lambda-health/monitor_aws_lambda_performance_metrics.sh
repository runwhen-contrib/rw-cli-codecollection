#!/bin/bash

# Environment Variables:
# AWS_REGION
source "$(dirname "$0")/auth.sh"
auth

START=$(date -d "60 minutes ago" +%s)
END=$(date +%s)
PERIOD=3600

lambda_functions=$(aws lambda list-functions --region "$AWS_REGION" --query 'Functions[*].[FunctionName]' --output text)
for lambda in $lambda_functions; do
    lambda_names+=("$lambda")
done

echo ------------------------
echo "Found lambda functions: ${lambda_names[*]}"
echo "Checking metrics: Duration, Errors, Throttles, Invocations"
echo "For the last 60 minutes"
echo ------------------------

for lambda_name in "${lambda_names[@]}"; do
    echo "Function Name: $lambda_name"
    echo "------------------------"
    aws cloudwatch get-metric-statistics --namespace AWS/Lambda --metric-name Duration \
    --dimensions Name=FunctionName,Value="$lambda_name" --statistics Average \
    --start-time "$START" \
    --end-time "$END" --period "$PERIOD" --region "$AWS_REGION"

    aws cloudwatch get-metric-statistics --namespace AWS/Lambda --metric-name Errors \
    --dimensions Name=FunctionName,Value="$lambda_name" --statistics Sum \
    --start-time "$START" \
    --end-time "$END" --period "$PERIOD" --region "$AWS_REGION"

    aws cloudwatch get-metric-statistics --namespace AWS/Lambda --metric-name Throttles \
    --dimensions Name=FunctionName,Value="$lambda_name" --statistics Sum \
    --start-time "$START" \
    --end-time "$END" --period "$PERIOD" --region "$AWS_REGION"

    aws cloudwatch get-metric-statistics --namespace AWS/Lambda --metric-name Invocations \
    --dimensions Name=FunctionName,Value="$lambda_name" --statistics Sum \
    --start-time "$START" \
    --end-time "$END" --period "$PERIOD" --region "$AWS_REGION"
done