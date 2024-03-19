*** Settings ***
Documentation       
Metadata            Author    jon-funk
Metadata            Display Name    ElastiCache Health Check
Metadata            Supports    `AWS`, `Elasticache`, `Redis`, `Service Down`
Metadata            Builder

Library             BuiltIn
Library             RW.Core
Library             RW.platform
Library             OperatingSystem
Library             String
Library             Process

Suite Setup         Suite Initialization

*** Tasks ***
Validate AWS Elasticache Redis Configuration
    [Documentation]   This script is used to retrieve and display the configuration details of an Amazon ElastiCache cluster. It fetches information such as the configuration endpoint, port, replication group ID, number of replicas, engine version, parameter group, and security groups.
    [Tags]  bash script    AWS Elasticache    configuration endpoint    configuration
    ${process}=    Run Process    ${CURDIR}/validate_aws_elasticache_redis_config.sh    env=${env}
    RW.Core.Add Pre To Report    ${process.stdout}
    IF    "Snapshot retention limit is set to 0" in ${process.stdout}
        RW.Core.Add Issue    title=Snapshots not configured for Elasticache
        ...    severity=4
        ...    next_steps=Update the configuration of the Elasticache instance(s) to include a retention limit for snapshots.        
    END
    IF    "is not available" in ${process.stdout}"
        RW.Core.Add Issue    title=Elasticache instance not available
        ...    severity=2
        ...    next_steps=Review metrics and logs of the Elasticache instance(s) to determine the cause of the issue.
        
    END

Analyze AWS Elasticache Redis Metrics
    [Documentation]   This script is used to analyze and monitor various aspects of an AWS ElastiCache Redis cluster. It retrieves and displays metrics related to CPU utilization, replication, persistence, performance, security, and overall cluster management.
    [Tags]  aws    bash    script    cloudwatch    metrics    elasticache    redis    replication    persistence
    ${process}=    Run Process    ${CURDIR}/analyze_aws_elasticache_redis_metrics.sh    env=${env}
    RW.Core.Add Pre To Report    ${process.stdout}
    IF    "" in ${process.stdout}
        RW.Core.Add Issue
        ...    title=ElastiCache Instances have events occuring
        ...    severity=3
        ...    next_steps=Review ElastiCache event logs.
    END

# TODO: discuss vpc topology and ec2 bastion access for aws redis elasticache
# Monitor Redis Performance using INFO and SLOWLOG commands
#     [Documentation]   This script is used to monitor the performance of a Redis instance hosted on AWS Elasticache. It first retrieves the details of the Redis instance using the AWS CLI. Then, it connects to the Redis instance and uses the Redis INFO and SLOWLOG commands to monitor its performance. The output of these commands is printed to the console for review.
#     [Tags]  AWS    ElastiCache    Redis    Performance Monitoring    SLOWLOG    INFO    BASH    CLI    Script    Cloud Services    Database    
#     ${process}=    Run Process    ${CURDIR}/monitor_redis_performance.sh    env=${env}
#     RW.Core.Add Pre To Report    ${process.stdout}


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