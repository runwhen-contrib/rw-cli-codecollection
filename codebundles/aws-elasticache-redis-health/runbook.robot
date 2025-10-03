*** Settings ***
Documentation       Checks the health status of Elasticache redis in the given region.
Metadata            Author    jon-funk
Metadata            Display Name    AWS ElastiCache Health Check
Metadata            Supports    AWS Elasticache Redis
Metadata            Builder

Library             BuiltIn
Library             RW.CLI
Library             RW.Core
Library             RW.platform
Library             OperatingSystem
Library             String
Library             Process

Suite Setup         Suite Initialization

*** Tasks ***
Scan AWS Elasticache Redis Status in AWS Region `${AWS_REGION}`
    [Documentation]   Checks the high level metrics and status of the elasticache redis instances in the region.
    [Tags]  AWS Elasticache    configuration endpoint    configuration    access:read-only
    ${process}=    RW.CLI.Run Bash File    analyze_aws_elasticache_redis_metrics.sh
    ...    env=${env}
    ...    secret__AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID}
    ...    secret__AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY}
    ...    secret__AWS_ROLE_ARN=${AWS_ROLE_ARN}
    RW.Core.Add Pre To Report    ${process.stdout}
    IF    "Snapshot retention limit is set to 0" in """${process.stdout}"""
        ${issue_timestamp}=    RW.Core.Get Issue Timestamp

        RW.Core.Add Issue    title=Snapshots not configured for Elasticache in region ${AWS_REGION}
        ...    severity=4
        ...    next_steps=Update the configuration of the Elasticache instance(s) to include a retention limit for snapshots.      
        ...    expected=The Elasticache instance(s) should have a retention limit for snapshots.
        ...    actual=The Elasticache instance(s) does not have a retention limit for snapshots.
        ...    reproduce_hint=Check the AWS Management Console for the configuration of the Elasticache instance(s).
        ...    details=${process.stdout}
        ...    observed_at=${issue_timestamp}
    END
    IF    "is not available" in """${process.stdout}"""
        ${issue_timestamp}=    RW.Core.Get Issue Timestamp

        RW.Core.Add Issue    title=Elasticache instance(s) not available in region ${AWS_REGION}
        ...    severity=2
        ...    next_steps=Review metrics of the Elasticache instance(s) to determine the cause of the issue.
        ...    expected=The Elasticache instance(s) should be available in the specified region.
        ...    actual=The Elasticache instance(s) is not available in the specified region.
        ...    reproduce_hint=Check the AWS Management Console for the status of the Elasticache instance(s).
        ...    details=${process.stdout}
        ...    observed_at=${issue_timestamp}
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
