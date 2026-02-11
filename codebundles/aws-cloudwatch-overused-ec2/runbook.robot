*** Settings ***
Documentation       Queries AWS CloudWatch for a list of EC2 instances with a high amount of resource utilization, raising issues when overutilized instances are found.
Metadata            Author    jon-funk
Metadata            Display Name    AWS CloudWatch Overutlized EC2 Inspection
Metadata            Supports    AWS,CloudWatch

Library             RW.Core
Library             RW.CLI

Suite Setup         Suite Initialization


*** Tasks ***
Check For Overutilized Ec2 Instances
    [Documentation]    Fetches CloudWatch metrics for a list of EC2 instances and raises issues if they're over-utilized based on a configurable threshold.
    [Tags]    cloudwatch    metrics    ec2    utilization    data:config
    ${now}=    RW.CLI.String To Datetime    0h
    ${past_time}=    RW.CLI.String To Datetime    3h
    ${util_metrics}=    RW.CLI.Run Cli
    ...    cmd=${AWS_ASSUME_ROLE_CMD} aws cloudwatch get-metric-data --start-time ${past_time} --end-time ${now} --metric-data-queries '[{"Id":"runWhenMetric","Expression":"SELECT MAX(CPUUtilization) FROM \\"AWS/EC2\\" GROUP BY InstanceId","Period":60,"ReturnData":true}]' | jq -r '.MetricDataResults[] | select(.Values|max > ${UTILIZATION_THRESHOLD}) | "Instance:" + .Label + "Max Detected Utilization:" + (.Values|max|tostring)'
    ...    target_service=${AWS_SERVICE}
    ...    secret__aws_access_key_id=${aws_access_key_id}
    ...    secret__aws_secret_access_key=${aws_secret_access_key}
    ...    secret__aws_role_arn=${aws_role_arn}
    ...    secret__aws_assume_role_name=${aws_assume_role_name}
    # Check if any instances are over-utilized
    ${contains_instance}=    Run Keyword And Return Status    Should Contain    ${util_metrics.stdout}    Instance
    IF    ${contains_instance}
        RW.Core.Add Issue
        ...    severity=4
        ...    expected=EC2 instance is not overutilized
        ...    actual=EC2 instances detected past `${UTILIZATION_THRESHOLD}` utilization threshold
        ...    title=EC2 Instances Over Utilized in AWS Account
        ...    details=The following EC2 instances have been detected as over-utilized: \n\n${util_metrics.stdout}
        ...    reproduce_hint=Check CloudWatch metrics for EC2 instances with high CPU utilization
        ...    next_steps=Review instance sizing, consider scaling up instances or optimizing workloads to reduce CPU usage
    END
    RW.Core.Add Pre To Report
    ...    The following EC2 instances in ${AWS_DEFAULT_REGION} are classified as over-utilized according to the threshold: ${UTILIZATION_THRESHOLD}:\n\n
    RW.Core.Add Pre To Report    ${util_metrics.stdout}
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Commands Used: ${history}


*** Keywords ***
Suite Initialization
    ${AWS_SERVICE}=    RW.Core.Import Service    aws
    ...    type=string
    ...    description=The selected RunWhen Service to use for accessing services within a network.
    ...    pattern=\w*
    ...    example=aws-service.shared
    ...    default=aws-service.shared
    ${aws_access_key_id}=    RW.Core.Import Secret    aws_access_key_id
    ...    type=string
    ...    description=The AWS access key ID to use for connecting to AWS APIs.
    ...    pattern=\w*
    ...    example=SUPERSECRETKEYID
    ${aws_secret_access_key}=    RW.Core.Import Secret    aws_secret_access_key
    ...    type=string
    ...    description=The AWS access key to use for connecting to AWS APIs.
    ...    pattern=\w*
    ...    example=SUPERSECRETKEY
    ${aws_role_arn}=    RW.Core.Import Secret    aws_role_arn
    ...    type=string
    ...    description=The AWS role ARN to use for connecting to AWS APIs.
    ...    pattern=\w*
    ...    example=arn:aws:iam::ACCOUNT_ID:role/ROLE_NAME
    ${aws_assume_role_name}=    RW.Core.Import Secret    aws_assume_role_name
    ...    type=string
    ...    description=The AWS role ARN to use for connecting to AWS APIs.
    ...    pattern=\w*
    ...    example=runwhen-sa
    ${AWS_DEFAULT_REGION}=    RW.Core.Import User Variable    AWS_DEFAULT_REGION
    ...    type=string
    ...    description=The AWS region to scope API requests to.
    ...    pattern=\w*
    ...    example=us-west-1
    ...    default=us-west-1
    ${UTILIZATION_THRESHOLD}=    RW.Core.Import User Variable    UTILIZATION_THRESHOLD
    ...    type=string
    ...    description=The threshold at which an instance is determined as overutilized.
    ...    pattern=\w*
    ...    example=0.8
    ...    default=0.8
    Set Suite Variable    ${aws_access_key_id}    ${aws_access_key_id}
    Set Suite Variable    ${aws_secret_access_key}    ${aws_secret_access_key}
    Set Suite Variable    ${aws_role_arn}    ${aws_role_arn}
    Set Suite Variable    ${aws_assume_role_name}    ${aws_assume_role_name}
    Set Suite Variable    ${AWS_DEFAULT_REGION}    ${AWS_DEFAULT_REGION}
    Set Suite Variable    ${AWS_SERVICE}    ${AWS_SERVICE}
    Set Suite Variable    ${UTILIZATION_THRESHOLD}    ${UTILIZATION_THRESHOLD}
    Set Suite Variable
    ...    ${AWS_ASSUME_ROLE_CMD}
    ...    role_json=$(AWS_ACCESS_KEY_ID=$${aws_access_key_id.key} AWS_SECRET_ACCESS_KEY=$${aws_secret_access_key.key} AWS_DEFAULT_REGION=${AWS_DEFAULT_REGION} aws sts assume-role --role-arn $${aws_role_arn.key} --role-session-name ${aws_assume_role_name.key}) && AWS_DEFAULT_REGION=${AWS_DEFAULT_REGION} AWS_ACCESS_KEY_ID=$(echo $role_json | jq -r '.Credentials.AccessKeyId') AWS_SECRET_ACCESS_KEY=$(echo $role_json | jq -r '.Credentials.SecretAccessKey') AWS_SESSION_TOKEN=$(echo $role_json | jq -r '.Credentials.SessionToken')

