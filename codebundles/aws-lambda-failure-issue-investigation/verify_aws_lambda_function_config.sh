#!/bin/bash

# Variables
AWS_REGION="us-west-2"
LAMBDA_FUNCTION_NAME="my-lambda-function"

# Verify AWS Lambda Function Configuration
echo "Verifying AWS Lambda Function Configuration..."

# Get the function configuration
aws lambda get-function-configuration \
    --function-name $LAMBDA_FUNCTION_NAME \
    --region $AWS_REGION

# Check if the command was successful
if [ $? -eq 0 ]; then
    echo "Successfully retrieved the function configuration."
else
    echo "Failed to retrieve the function configuration."
    exit 1
fi

# Get the function policy
aws lambda get-policy \
    --function-name $LAMBDA_FUNCTION_NAME \
    --region $AWS_REGION

# Check if the command was successful
if [ $? -eq 0 ]; then
    echo "Successfully retrieved the function policy."
else
    echo "Failed to retrieve the function policy."
    exit 1
fi

# List all the function aliases
aws lambda list-aliases \
    --function-name $LAMBDA_FUNCTION_NAME \
    --region $AWS_REGION

# Check if the command was successful
if [ $? -eq 0 ]; then
    echo "Successfully listed all the function aliases."
else
    echo "Failed to list all the function aliases."
    exit 1
fi

# List all the function versions
aws lambda list-versions-by-function \
    --function-name $LAMBDA_FUNCTION_NAME \
    --region $AWS_REGION

# Check if the command was successful
if [ $? -eq 0 ]; then
    echo "Successfully listed all the function versions."
else
    echo "Failed to list all the function versions."
    exit 1
fi

echo "AWS Lambda Function Configuration verification completed successfully."
