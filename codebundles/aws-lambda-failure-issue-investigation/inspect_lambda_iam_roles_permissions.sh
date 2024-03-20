#!/bin/bash

# Variables
AWS_REGION="us-east-1"
LAMBDA_FUNCTION_NAME="your_lambda_function_name"

# List IAM roles
echo "Listing IAM roles..."
aws iam list-roles --region $AWS_REGION

# Get the IAM role for the Lambda function
LAMBDA_ROLE=$(aws lambda get-function-configuration --function-name $LAMBDA_FUNCTION_NAME --region $AWS_REGION --query 'Role' --output text)
echo "The IAM role for the Lambda function $LAMBDA_FUNCTION_NAME is $LAMBDA_ROLE"

# Get the policy attached to the IAM role
POLICY=$(aws iam list-attached-role-policies --role-name $LAMBDA_ROLE --region $AWS_REGION --query 'AttachedPolicies[0].PolicyArn' --output text)
echo "The policy attached to the IAM role $LAMBDA_ROLE is $POLICY"

# Get the policy document
echo "Getting the policy document..."
aws iam get-policy-version --policy-arn $POLICY --version-id v1 --region $AWS_REGION --query 'PolicyVersion.Document' --output json

# List resources that the Lambda function has access to
echo "Listing resources that the Lambda function has access to..."
aws lambda get-policy --function-name $LAMBDA_FUNCTION_NAME --region $AWS_REGION --query 'Policy' --output json