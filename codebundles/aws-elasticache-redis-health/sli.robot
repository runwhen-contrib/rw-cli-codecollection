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
    ...    secret__AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID}
    ...    secret__AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY}
    ...    secret__AWS_ROLE_ARN=${AWS_ROLE_ARN}
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
    ${AWS_REGION}=    RW.Core.Import User Variable    AWS_REGION
    ...    type=string
    ...    description=AWS Region
    ...    pattern=\w*
    ${AWS_ACCESS_KEY_ID}=    RW.Core.Import Secret   AWS_ACCESS_KEY_ID
    ...    type=string
    ...    description=AWS Access Key ID
    ...    pattern=\w*
    ${AWS_SECRET_ACCESS_KEY}=    RW.Core.Import Secret   AWS_SECRET_ACCESS_KEY
    ...    type=string
    ...    description=AWS Secret Access Key
    ...    pattern=\w*
    ${AWS_ROLE_ARN}=    RW.Core.Import Secret   AWS_ROLE_ARN
    ...    type=string
    ...    description=AWS Role ARN
    ...    pattern=\w*

    Set Suite Variable    ${AWS_REGION}    ${AWS_REGION}
    Set Suite Variable    ${AWS_ACCESS_KEY_ID}    ${AWS_ACCESS_KEY_ID}
    Set Suite Variable    ${AWS_SECRET_ACCESS_KEY}    ${AWS_SECRET_ACCESS_KEY}
    Set Suite Variable    ${AWS_ROLE_ARN}    ${AWS_ROLE_ARN}

    Set Suite Variable
    ...    &{env}
    ...    AWS_REGION=${AWS_REGION}