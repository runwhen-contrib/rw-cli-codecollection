*** Settings ***
Documentation       
Metadata            Author    jon-funk
Metadata            Display Name    aws-elasticache-redis-service-down
Metadata            Supports    `AWS`, `Elasticache`, `Redis`, `Service Down`, `Investigation`, `Developer`, `Incident`, `Solution Implementation`, `Status Update`, 
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
    [Documentation]   This script is used to retrieve and display the configuration details of an Amazon ElastiCache cluster. It fetches information such as the configuration endpoint, port, replication group ID, number of replicas, engine version, parameter group, and security groups. The AWS CLI is used to interact with the AWS ElastiCache service. The script assumes that the AWS CLI is configured with appropriate AWS credentials.
    [Tags]  bash script    AWS Elasticache    configuration endpoint
    ${process}=    Run Process    ${CURDIR}/validate_aws_elasticache_redis_config.sh    env=${env}
    RW.Core.Add Pre To Report    ${process.stdout}

Analyze AWS Elasticache Redis Metrics
    [Documentation]   This script is used to analyze and monitor various aspects of an AWS ElastiCache Redis cluster. It retrieves and displays metrics related to CPU utilization, replication, persistence, performance, security, and overall cluster management. The script makes use of the AWS CLI to interact with the AWS CloudWatch and ElastiCache services.
    [Tags]  aws    bash    script    cloudwatch    metrics    elasticache    redis    replication    persistence
    ${process}=    Run Process    ${CURDIR}/analyze_aws_elasticache_redis_metrics.sh    env=${env}
    RW.Core.Add Pre To Report    ${process.stdout}

Test AWS Elasticache Redis Connectivity
    [Documentation]   This script is designed to test connectivity to an AWS ElastiCache Redis cluster. It first fetches the endpoint for the specified ElastiCache cluster in the specified AWS region. If the endpoint is fetched successfully, it then attempts to connect to the Redis cluster using the provided password and tests the connection by sending a PING command. If the connection is successful, it prints a success message; if not, it prints an error message and exits with a status of 1.
    [Tags]  AWS    ElastiCache    Redis    Connectivity    Endpoint    Bash Script    Cluster ID    AWS Region    Network    Redis Password    
    ${process}=    Run Process    ${CURDIR}/test_aws_elasticache_redis_connectivity.sh    env=${env}
    RW.Core.Add Pre To Report    ${process.stdout}

Monitor Redis Performance using INFO and SLOWLOG commands
    [Documentation]   This script is used to monitor the performance of a Redis instance hosted on AWS Elasticache. It first retrieves the details of the Redis instance using the AWS CLI. Then, it connects to the Redis instance and uses the Redis INFO and SLOWLOG commands to monitor its performance. The output of these commands is printed to the console for review.
    [Tags]  AWS    ElastiCache    Redis    Performance Monitoring    SLOWLOG    INFO    BASH    CLI    Script    Cloud Services    Database    
    ${process}=    Run Process    ${CURDIR}/monitor_redis_performance.sh    env=${env}
    RW.Core.Add Pre To Report    ${process.stdout}


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

    ${METRIC_NAMESPACE}=    RW.Core.Import User Variable    METRIC_NAMESPACE
    ...    type=string
    ...    description=Runbook input.
    ...    pattern=\w*
    ...    default=placeholder

    ${METRIC_NAME}=    RW.Core.Import User Variable    METRIC_NAME
    ...    type=string
    ...    description=Runbook input.
    ...    pattern=\w*
    ...    default=placeholder

    ${START_TIME}=    RW.Core.Import User Variable    START_TIME
    ...    type=string
    ...    description=Runbook input.
    ...    pattern=\w*
    ...    default=placeholder

    ${END_TIME}=    RW.Core.Import User Variable    END_TIME
    ...    type=string
    ...    description=Runbook input.
    ...    pattern=\w*
    ...    default=placeholder

    ${STATISTICS}=    RW.Core.Import User Variable    STATISTICS
    ...    type=string
    ...    description=Runbook input.
    ...    pattern=\w*
    ...    default=placeholder

    ${PERIOD}=    RW.Core.Import User Variable    PERIOD
    ...    type=string
    ...    description=Runbook input.
    ...    pattern=\w*
    ...    default=placeholder

    ${REPLICATION_GROUP_ID}=    RW.Core.Import User Variable    REPLICATION_GROUP_ID
    ...    type=string
    ...    description=Runbook input.
    ...    pattern=\w*
    ...    default=placeholder

    ${SECURITY_GROUP_ID}=    RW.Core.Import User Variable    SECURITY_GROUP_ID
    ...    type=string
    ...    description=Runbook input.
    ...    pattern=\w*
    ...    default=placeholder

    ${REDIS_HOST}=    RW.Core.Import User Variable    REDIS_HOST
    ...    type=string
    ...    description=Runbook input.
    ...    pattern=\w*
    ...    default=placeholder

    ${REDIS_PORT}=    RW.Core.Import User Variable    REDIS_PORT
    ...    type=string
    ...    description=Runbook input.
    ...    pattern=\w*
    ...    default=placeholder

    ${REDIS_PASSWORD}=    RW.Core.Import User Variable    REDIS_PASSWORD
    ...    type=string
    ...    description=Runbook input.
    ...    pattern=\w*
    ...    default=placeholder

    ${SLOWLOG_ENTRY_LIMIT}=    RW.Core.Import User Variable    SLOWLOG_ENTRY_LIMIT
    ...    type=string
    ...    description=Runbook input.
    ...    pattern=\w*
    ...    default=placeholder

    ${ELASTICACHE_CLUSTER_ID}=    RW.Core.Import User Variable    ELASTICACHE_CLUSTER_ID
    ...    type=string
    ...    description=Runbook input.
    ...    pattern=\w*
    ...    default=placeholder

    ${ELASTICACHE_ENDPOINT}=    RW.Core.Import User Variable    ELASTICACHE_ENDPOINT
    ...    type=string
    ...    description=Runbook input.
    ...    pattern=\w*
    ...    default=placeholder

    ${ELASTICACHE_PORT}=    RW.Core.Import User Variable    ELASTICACHE_PORT
    ...    type=string
    ...    description=Runbook input.
    ...    pattern=\w*
    ...    default=placeholder


    Set Suite Variable    ${AWS_REGION}    ${AWS_REGION.value}
    Set Suite Variable    ${AWS_ACCESS_KEY_ID}    ${AWS_ACCESS_KEY_ID.value}
    Set Suite Variable    ${AWS_SECRET_ACCESS_KEY}    ${AWS_SECRET_ACCESS_KEY.value}
    Set Suite Variable    ${METRIC_NAMESPACE}    ${METRIC_NAMESPACE}
    Set Suite Variable    ${METRIC_NAME}    ${METRIC_NAME}
    Set Suite Variable    ${START_TIME}    ${START_TIME}
    Set Suite Variable    ${END_TIME}    ${END_TIME}
    Set Suite Variable    ${STATISTICS}    ${STATISTICS}
    Set Suite Variable    ${PERIOD}    ${PERIOD}
    Set Suite Variable    ${REPLICATION_GROUP_ID}    ${REPLICATION_GROUP_ID}
    Set Suite Variable    ${SECURITY_GROUP_ID}    ${SECURITY_GROUP_ID}
    Set Suite Variable    ${REDIS_HOST}    ${REDIS_HOST}
    Set Suite Variable    ${REDIS_PORT}    ${REDIS_PORT}
    Set Suite Variable    ${REDIS_PASSWORD}    ${REDIS_PASSWORD}
    Set Suite Variable    ${SLOWLOG_ENTRY_LIMIT}    ${SLOWLOG_ENTRY_LIMIT}
    Set Suite Variable    ${ELASTICACHE_CLUSTER_ID}    ${ELASTICACHE_CLUSTER_ID}
    Set Suite Variable    ${ELASTICACHE_ENDPOINT}    ${ELASTICACHE_ENDPOINT}
    Set Suite Variable    ${ELASTICACHE_PORT}    ${ELASTICACHE_PORT}

    Set Suite Variable
    ...    &{env}
    ...    AWS_REGION=${AWS_REGION}
    ...    AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID}
    ...    AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY}
    ...    METRIC_NAMESPACE=${METRIC_NAMESPACE}
    ...    METRIC_NAME=${METRIC_NAME}
    ...    START_TIME=${START_TIME}
    ...    END_TIME=${END_TIME}
    ...    STATISTICS=${STATISTICS}
    ...    PERIOD=${PERIOD}
    ...    REPLICATION_GROUP_ID=${REPLICATION_GROUP_ID}
    ...    SECURITY_GROUP_ID=${SECURITY_GROUP_ID}
    ...    REDIS_HOST=${REDIS_HOST}
    ...    REDIS_PORT=${REDIS_PORT}
    ...    REDIS_PASSWORD=${REDIS_PASSWORD}
    ...    SLOWLOG_ENTRY_LIMIT=${SLOWLOG_ENTRY_LIMIT}
    ...    ELASTICACHE_CLUSTER_ID=${ELASTICACHE_CLUSTER_ID}
    ...    ELASTICACHE_ENDPOINT=${ELASTICACHE_ENDPOINT}
    ...    ELASTICACHE_PORT=${ELASTICACHE_PORT}