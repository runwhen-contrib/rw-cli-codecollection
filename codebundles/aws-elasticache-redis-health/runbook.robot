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
Scan AWS Elasticache Redis Status
    [Documentation]   Checks the high level metrics and status of the elasticache redis instances in the region.
    [Tags]  AWS Elasticache    configuration endpoint    configuration
    ${process}=    RW.CLI.Run Bash File    analyze_aws_elasticache_redis_metrics.sh
    ...    env=${env}
    ...    secret__AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID}
    ...    secret__AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY}
    RW.Core.Add Pre To Report    ${process.stdout}
    IF    "Snapshot retention limit is set to 0" in """${process.stdout}"""
        RW.Core.Add Issue    title=Snapshots not configured for Elasticache in region ${AWS_REGION}
        ...    severity=4
        ...    next_steps=Update the configuration of the Elasticache instance(s) to include a retention limit for snapshots.      
        ...    expected=The Elasticache instance(s) should have a retention limit for snapshots.
        ...    actual=The Elasticache instance(s) does not have a retention limit for snapshots.
        ...    reproduce_hint=Check the AWS Management Console for the configuration of the Elasticache instance(s).
        ...    details=${process.stdout}  
    END
    IF    "is not available" in """${process.stdout}"""
        RW.Core.Add Issue    title=Elasticache instance(s) not available in region ${AWS_REGION}
        ...    severity=2
        ...    next_steps=Review metrics of the Elasticache instance(s) to determine the cause of the issue.
        ...    expected=The Elasticache instance(s) should be available in the specified region.
        ...    actual=The Elasticache instance(s) is not available in the specified region.
        ...    reproduce_hint=Check the AWS Management Console for the status of the Elasticache instance(s).
        ...    details=${process.stdout}
    END

# TODO: discuss vpc topology and ec2 bastion access for aws redis elasticache
# Monitor Redis Performance using INFO and SLOWLOG commands
#     [Documentation]   This script is used to monitor the performance of a Redis instance hosted on AWS Elasticache. It first retrieves the details of the Redis instance using the AWS CLI. Then, it connects to the Redis instance and uses the Redis INFO and SLOWLOG commands to monitor its performance. The output of these commands is printed to the console for review.
#     [Tags]  AWS    ElastiCache    Redis    Performance Monitoring    SLOWLOG    INFO    BASH    CLI    Script    Cloud Services    Database    
#     ${process}=    Run Process    ${CURDIR}/monitor_redis_performance.sh    env=${env}
#     RW.Core.Add Pre To Report    ${process.stdout}


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


    Set Suite Variable    ${AWS_REGION}    ${AWS_REGION}
    Set Suite Variable    ${AWS_ACCESS_KEY_ID}    ${AWS_ACCESS_KEY_ID}
    Set Suite Variable    ${AWS_SECRET_ACCESS_KEY}    ${AWS_SECRET_ACCESS_KEY}


    Set Suite Variable
    ...    &{env}
    ...    AWS_REGION=${AWS_REGION}
