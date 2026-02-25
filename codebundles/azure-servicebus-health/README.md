# Azure Service Bus Health

This codebundle performs a health check on Azure Service Bus resources and provides insights and recommended actions for detected issues.

## Scripts

The codebundle includes the following scripts:

- **service_bus_resource_health.sh**: Checks the Azure Resource Health status of the Service Bus namespace
- **service_bus_config_health.sh**: Analyzes the configuration of the Service Bus namespace for best practices
- **service_bus_metrics.sh**: Retrieves and analyzes Service Bus metrics for potential issues
- **service_bus_queue_health.sh**: Checks the health of Service Bus queues (message counts, size, status)
- **service_bus_topic_health.sh**: Checks the health of Service Bus topics and their subscriptions
- **service_bus_log_analytics.sh**: Queries Log Analytics for Service Bus related logs and errors
- **service_bus_capacity.sh**: Analyzes capacity utilization and quota headroom
- **service_bus_disaster_recovery.sh**: Checks geo-disaster recovery configuration and health
- **service_bus_security_audit.sh**: Audits SAS keys and RBAC assignments for security best practices
- **service_bus_related_resources.sh**: Discovers and maps Azure resources related to the Service Bus
- **service_bus_connectivity_test.sh**: Tests network connectivity to the Service Bus namespace
- **service_bus_alerts_check.sh**: Checks for the presence and configuration of Azure Monitor alerts

## Tasks

The runbook contains tasks to:

1. Check Resource Health status for Service Bus namespaces
2. Validate Service Bus configuration against best practices
3. Analyze Service Bus metrics for anomalies
4. Check queue health (dead letters, message counts, size limits)
5. Check topic and subscription health
6. Query and analyze logs from Log Analytics
7. Analyze capacity utilization and quota headroom
8. Check geo-disaster recovery configuration
9. Audit security configurations (SAS keys, RBAC)
10. Discover and map related Azure resources
11. Test network connectivity to the Service Bus
12. Check for proper Azure Monitor alerts

## Required Variables

- `AZ_RESOURCE_GROUP`: The resource group containing the Service Bus namespace
- `SB_NAMESPACE_NAME`: The name of the Service Bus namespace to check

## Optional Variables

- `AZURE_RESOURCE_SUBSCRIPTION_ID`: The subscription ID (defaults to current az login context)
- `METRIC_INTERVAL`: Time interval for metrics in ISO 8601 format (default: PT1H - 1 hour)
- `QUERY_TIMESPAN`: Time span for log queries (default: P1D - 1 day)
- `SAS_KEY_MAX_AGE_DAYS`: Maximum age for SAS keys in days (default: 90)

### Configurable Thresholds

- `ACTIVE_MESSAGE_THRESHOLD`: Threshold for active message count alerts (default: 1000)
- `DEAD_LETTER_THRESHOLD`: Threshold for dead letter message count alerts (default: 100)
- `SIZE_PERCENTAGE_THRESHOLD`: Size percentage threshold for namespace/queue/topic alerts (default: 80)
- `LATENCY_THRESHOLD_MS`: Latency threshold in milliseconds for connectivity alerts (default: 100)

## Authentication

This codebundle requires Azure credentials with read access to the Service Bus namespace and related resources.

## Local Testing

Azure Auth
```
ln -s ~/.azure/ /var/tmp/runwhen/azure-servicebus-health/runbook.robot/
ln -s ~/.azure/ /var/tmp/runwhen/azure-servicebus-health/sli.robot/
