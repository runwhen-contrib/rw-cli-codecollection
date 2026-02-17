#!/bin/bash
source "$(dirname "$0")/auth.sh"
auth

# Fetch all Lambda function names
function_names=$(aws lambda list-functions --query 'Functions[*].FunctionName' --output text)

# Iterate over each function name
for function_name in $function_names; do
    # Fetch runtime and version for each function
    runtime=$(aws lambda get-function --function-name $function_name --query 'Configuration.Runtime' --output text)
    version=$(aws lambda get-function --function-name $function_name --query 'Configuration.Version' --output text)

    # Print function name, runtime, and version
    echo "Function Name: $function_name"
    echo "Runtime: $runtime"
    echo "Version: $version"
    echo "------------------------"
done