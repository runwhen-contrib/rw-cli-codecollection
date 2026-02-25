# aws-elasticache-redis-service-down CodeBundle
### Tags:`AWS`, `Elasticache`, `Redis`
## CodeBundle Objective:
This runbook provides a comprehensive guide to managing and troubleshooting AWS Elasticache Redis configurations. It details procedures for validating configurations, analyzing metrics, and performing a broad fleet scan.

## CodeBundle Inputs

On the platform: `AWS_REGION`, `aws_credentials` (from aws-auth block).

**Local testing:** Set `AWS_REGION`, and either `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` or `AWS_PROFILE`. For the runbook via CLI, add `RW_FROM_FILE='{"aws_credentials":"/path/or-placeholder"}'`.

---

export AWS_REGION="PLACEHOLDER"

export AWS_ACCESS_KEY_ID="PLACEHOLDER"

export AWS_SECRET_ACCESS_KEY="PLACEHOLDER"


## CodeBundle Tasks:
### `Validate AWS Elasticache Redis State`
#### Tags:`AWS Elasticache`
### Task Documentation:
Scans the current fleet of ElastiCache instances configuration and state for issues.
#### Usage Example:
`./validate_aws_elasticache_redis_config.sh`

### `Analyze AWS Elasticache Redis Metrics`
#### Tags:`aws`, `bash`, `script`, `cloudwatch`, `metrics`, `elasticache`, `redis`
### Task Documentation:
Fetches all events for a fleet of ElastiCache instances and raises issues for present events.
#### Usage Example:
`./analyze_aws_elasticache_redis_metrics.sh`