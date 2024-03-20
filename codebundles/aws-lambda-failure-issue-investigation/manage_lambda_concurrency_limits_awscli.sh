#!/bin/bash

# Variables
FUNCTION_NAME="YourLambdaFunctionName"
NEW_CONCURRENCY_LIMIT=100

# Get the current concurrency limit
CURRENT_CONCURRENCY_LIMIT=$(aws lambda get-function-concurrency --function-name $FUNCTION_NAME --query 'ReservedConcurrentExecutions' --output text)

# Display the current concurrency limit
echo "Current concurrency limit for $FUNCTION_NAME is $CURRENT_CONCURRENCY_LIMIT"

# Set the new concurrency limit
aws lambda put-function-concurrency --function-name $FUNCTION_NAME --reserved-concurrent-executions $NEW_CONCURRENCY_LIMIT

# Verify the new concurrency limit
NEW_CONCURRENCY_LIMIT_CHECK=$(aws lambda get-function-concurrency --function-name $FUNCTION_NAME --query 'ReservedConcurrentExecutions' --output text)

# Display the new concurrency limit
echo "New concurrency limit for $FUNCTION_NAME is $NEW_CONCURRENCY_LIMIT_CHECK"

# Check if the new concurrency limit has been set correctly
if [ $NEW_CONCURRENCY_LIMIT_CHECK -eq $NEW_CONCURRENCY_LIMIT ]; then
    echo "Concurrency limit for $FUNCTION_NAME has been updated successfully"
else
    echo "Failed to update concurrency limit for $FUNCTION_NAME"
fi