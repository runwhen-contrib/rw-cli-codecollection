#!/bin/bash
source ./auth.sh

# Environment Variables:
#AWS_REGION


SINCE="24h"

lambda_names=()
lambda_functions=$(aws lambda list-functions --region "$AWS_REGION" --query 'Functions[*].[FunctionName]' --output text)
for lambda in $lambda_functions; do
    lambda_names+=("$lambda")
done

err_lambdas=() # Empty array to store lambda names with errors
lambda_arns=() # Empty array to store lambda arns

echo "Found lambda functions: ${lambda_names[*]}"
# Loop through the lambda functions
for lambda_function in $lambda_functions; do
    lambda_arn=$(aws lambda list-functions --region "$AWS_REGION" | jq -r '.Functions[] | select(.FunctionName=="'$lambda_function'") | .FunctionArn')
    lambda_arns+=("$lambda_arn")
done
echo "Found lambda arns: ${lambda_arns[*]}"

for lambda_name in "${lambda_names[@]}"; do
    # logstream=$(aws logs describe-log-streams --log-group-name /aws/lambda/"$lambda_name" --region "$AWS_REGION" | jq -r '.logStreams[-1] | .logStreamName')
    log_messages=$(aws logs tail /aws/lambda/"$lambda_name" --since $SINCE --region "$AWS_REGION")
    # log_messages=$(aws logs get-log-events --log-group-name /aws/lambda/"$lambda_name" --log-stream-name "$logstream" --start-time "$HOURS_IN_PAST" --query events[].message --output text)
    if [[ $log_messages == *"ERROR"* ]]; then
        err_lambdas+=("----------------------------------\n$lambda_name contains error:\n\n$log_messages\n\n")
    fi
done
echo -e "${err_lambdas[@]}"
echo "----------------------------------"