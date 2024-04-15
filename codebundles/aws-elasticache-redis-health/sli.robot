*** Settings ***
Documentation       
Metadata            Author    jon-funk
Metadata            Display Name    ElastiCache Health Monitor
Metadata            Supports    AWS, Elasticache, Redis
Metadata            Builder

Library             BuiltIn
Library             RW.Core
Library             RW.platform
Library             OperatingSystem
Library             String
Library             Process

Suite Setup         Suite Initialization

*** Tasks ***
Scan ElastiCaches
    [Documentation]   Performs a broad health scan of all Elasticache instances in the region.
    [Tags]  bash script    AWS Elasticache    Health
    ${process}=    Run Process    ${CURDIR}/redis_status_scan.sh    env=${env}
    Log    ${process.stdout}
    Log    ${process.stderr}
    IF    ${process.rc} != 0
        RW.Core.Push Metric    0
    ELSE
        RW.Core.Push Metric    1
    END


*** Keywords ***
Suite Initialization
    ${AWS_REGION}=    RW.Core.Import Secret    AWS_REGION
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

    Set Suite Variable    ${AWS_REGION}    ${AWS_REGION.value}
    Set Suite Variable    ${AWS_ACCESS_KEY_ID}    ${AWS_ACCESS_KEY_ID.value}
    Set Suite Variable    ${AWS_SECRET_ACCESS_KEY}    ${AWS_SECRET_ACCESS_KEY.value}

    Set Suite Variable
    ...    &{env}
    ...    AWS_REGION=${AWS_REGION}
    ...    AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID}
    ...    AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY}