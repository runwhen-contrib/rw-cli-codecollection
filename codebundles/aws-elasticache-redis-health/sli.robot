*** Settings ***
Documentation       Monitors the health status of elasticache redis in the AWS region.
Metadata            Author    jon-funk
Metadata            Display Name    AWS ElastiCache Health Monitor
Metadata            Supports    AWS Elasticache Redis
Metadata            Builder

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             OperatingSystem
Library             String
Library             Process

Suite Setup         Suite Initialization

*** Tasks ***
Scan ElastiCaches in AWS Region `${AWS_REGION}`
    [Documentation]   Performs a broad health scan of all Elasticache instances in the region.
    [Tags]  bash script    AWS Elasticache    Health
    ${process}=    RW.CLI.Run Bash File    redis_status_scan.sh
    ...    env=${env}
    Log    ${process.stdout}
    Log    ${process.stderr}
    IF    ${process.rc} != 0
        RW.Core.Push Metric    0    sub_name=redis_health
        RW.Core.Push Metric    0
    ELSE
        RW.Core.Push Metric    1    sub_name=redis_health
        RW.Core.Push Metric    1
    END


*** Keywords ***
Suite Initialization
    # AWS credentials are provided by the platform from the aws-auth block (runwhen-local).
    ${AWS_REGION}=    RW.Core.Import User Variable    AWS_REGION
    ...    type=string
    ...    description=AWS Region
    ...    pattern=\w*
    ${aws_credentials}=    RW.Core.Import Secret    aws_credentials
    ...    type=string
    ...    description=AWS credentials from the workspace (from aws-auth block; e.g. aws:access_key@cli, aws:irsa@cli).
    ...    pattern=\w*

    Set Suite Variable    ${AWS_REGION}    ${AWS_REGION}
    Set Suite Variable    ${aws_credentials}    ${aws_credentials}

    Set Suite Variable
    ...    &{env}
    ...    AWS_REGION=${AWS_REGION}