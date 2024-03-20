# aws-elasticache-redis-service-down CodeBundle
### Tags:`AWS`, `Elasticache`, `Redis`, `Service Down`, `Investigation`, `Developer`, `Incident`, `Solution Implementation`, `Status Update`
## CodeBundle Objective:
This runbook provides a comprehensive guide to managing and troubleshooting AWS Elasticache Redis configurations. It details procedures for validating configurations, analyzing metrics, and performing a broad fleet scan.

## CodeBundle Inputs:

export AWS_REGION="PLACEHOLDER"

export AWS_ACCESS_KEY_ID="PLACEHOLDER"

export AWS_SECRET_ACCESS_KEY="PLACEHOLDER"


## CodeBundle Tasks:
### `Validate AWS Elasticache Redis State`
#### Tags:`bash script`, `AWS Elasticache`, `configuration endpoint`, `port`, `replication group ID`, `number of replicas`, `engine version`, `parameter group`, `security groups`, `AWS CLI`, `shell scripting`, `infrastructure management`, `cloud resources`, `AWS region`, `Elasticache cluster ID`, 
### Task Documentation:
Scans the current fleet of ElastiCache instances configuration and state for issues.
#### Usage Example:
`./validate_aws_elasticache_redis_config.sh`

### `Analyze AWS Elasticache Redis Metrics`
#### Tags:`aws`, `bash`, `script`, `cloudwatch`, `metrics`, `elasticache`, `redis`, `replication`, `persistence`, `performance`, `security`, `cluster management`, `CPU utilization`, `region`, `security group`, `replication group`, 
### Task Documentation:
Fetches all events for a fleet of ElastiCache instances and raises issues for present events.
#### Usage Example:
`./analyze_aws_elasticache_redis_metrics.sh`