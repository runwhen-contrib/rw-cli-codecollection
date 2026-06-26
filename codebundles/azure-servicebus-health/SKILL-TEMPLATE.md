---
name: azure-servicebus-health
kind: skill-template
description: Performs a health check on Azure Service Bus instances and the components using them, generating a report of issues... Use when triaging or monitoring Azure, ServiceBus workloads with skill templat...
runtime:
  runbook: runbook.robot
  monitor: sli.robot
  executor: worker
  entrypoint: /home/runwhen/robot-runtime/runrobot.sh
  base_image: rw-base-runtime
platforms: [Azure, ServiceBus]
resource_types: [service_bus]
access: read-only
---

# Azure Service Bus Health

## Summary

This codebundle performs a health check on Azure Service Bus resources and provides insights and recommended actions for detected issues.

See [README.md](README.md) for additional context.

## Tools

### Check for Resource Health Issues Service Bus `${SB_NAMESPACE_NAME}` In Resource Group `${AZ_RESOURCE_GROUP}`

Fetch a list of issues that might affect the service bus instance

- **Robot task name**: <code>Check for Resource Health Issues Service Bus `${SB_NAMESPACE_NAME}` In Resource Group `${AZ_RESOURCE_GROUP}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `service_bus_resource_health.sh`
- **Tags**: `azure`, `servicebus`, `resourcehealth`, `access:read-only`, `data:config`
- **Reads**: `AZ_RESOURCE_GROUP`, `SB_NAMESPACE_NAME`
- **Writes**: `service_bus_health.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Check Configuration Health for Service Bus `${SB_NAMESPACE_NAME}` In Resource Group `${AZ_RESOURCE_GROUP}`

Fetch the details and health of the service bus configuration

- **Robot task name**: <code>Check Configuration Health for Service Bus `${SB_NAMESPACE_NAME}` In Resource Group `${AZ_RESOURCE_GROUP}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `service_bus_config_health.sh`
- **Tags**: `servicebus`, `logs`, `config`, `access:read-only`, `data:config`
- **Reads**: `AZ_RESOURCE_GROUP`, `SB_NAMESPACE_NAME`
- **Writes**: `service_bus_config_health.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Check Metrics for Service Bus `${SB_NAMESPACE_NAME}` In Resource Group `${AZ_RESOURCE_GROUP}`

Analyze Service Bus metrics for potential issues

- **Robot task name**: <code>Check Metrics for Service Bus `${SB_NAMESPACE_NAME}` In Resource Group `${AZ_RESOURCE_GROUP}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `service_bus_metrics.sh`
- **Tags**: `servicebus`, `metrics`, `performance`, `access:read-only`, `data:config`
- **Reads**: `AZ_RESOURCE_GROUP`, `SB_NAMESPACE_NAME`
- **Writes**: `service_bus_metrics.json`, `service_bus_metrics_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Check Queue Health for Service Bus `${SB_NAMESPACE_NAME}` In Resource Group `${AZ_RESOURCE_GROUP}`

Analyze Service Bus queues for health issues

- **Robot task name**: <code>Check Queue Health for Service Bus `${SB_NAMESPACE_NAME}` In Resource Group `${AZ_RESOURCE_GROUP}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `service_bus_queue_health.sh`
- **Tags**: `servicebus`, `queues`, `messages`, `access:read-only`, `data:config`
- **Reads**: `AZ_RESOURCE_GROUP`, `SB_NAMESPACE_NAME`
- **Writes**: `service_bus_queues.json`, `service_bus_queue_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Check Topic Health for Service Bus `${SB_NAMESPACE_NAME}` In Resource Group `${AZ_RESOURCE_GROUP}`

Analyze Service Bus topics and subscriptions for health issues

- **Robot task name**: <code>Check Topic Health for Service Bus `${SB_NAMESPACE_NAME}` In Resource Group `${AZ_RESOURCE_GROUP}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `service_bus_topic_health.sh`
- **Tags**: `servicebus`, `topics`, `subscriptions`, `access:read-only`, `data:config`
- **Reads**: `AZ_RESOURCE_GROUP`, `SB_NAMESPACE_NAME`
- **Writes**: `service_bus_topics.json`, `service_bus_topic_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Check Log Analytics for Service Bus `${SB_NAMESPACE_NAME}` In Resource Group `${AZ_RESOURCE_GROUP}`

Query Log Analytics for Service Bus related logs and errors

- **Robot task name**: <code>Check Log Analytics for Service Bus `${SB_NAMESPACE_NAME}` In Resource Group `${AZ_RESOURCE_GROUP}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `service_bus_log_analytics.sh`
- **Tags**: `servicebus`, `logs`, `diagnostics`, `access:read-only`, `data:logs-regexp`
- **Reads**: `AZ_RESOURCE_GROUP`, `SB_NAMESPACE_NAME`
- **Writes**: `service_bus_logs.json`, `service_bus_log_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Check Capacity and Quota Headroom for Service Bus `${SB_NAMESPACE_NAME}` In Resource Group `${AZ_RESOURCE_GROUP}`

Analyze Service Bus capacity utilization and quota headroom

- **Robot task name**: <code>Check Capacity and Quota Headroom for Service Bus `${SB_NAMESPACE_NAME}` In Resource Group `${AZ_RESOURCE_GROUP}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `service_bus_capacity.sh`
- **Tags**: `servicebus`, `capacity`, `quota`, `access:read-only`, `data:config`
- **Reads**: `AZ_RESOURCE_GROUP`, `SB_NAMESPACE_NAME`
- **Writes**: `service_bus_capacity.json`, `service_bus_capacity_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Check Geo-Disaster Recovery for Service Bus `${SB_NAMESPACE_NAME}` In Resource Group `${AZ_RESOURCE_GROUP}`

Check the geo-disaster recovery configuration and health

- **Robot task name**: <code>Check Geo-Disaster Recovery for Service Bus `${SB_NAMESPACE_NAME}` In Resource Group `${AZ_RESOURCE_GROUP}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `service_bus_disaster_recovery.sh`
- **Tags**: `servicebus`, `disaster-recovery`, `geo-replication`, `access:read-only`, `data:config`
- **Reads**: `AZ_RESOURCE_GROUP`, `SB_NAMESPACE_NAME`
- **Writes**: `service_bus_dr.json`, `service_bus_dr_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Check Security Configuration for Service Bus `${SB_NAMESPACE_NAME}` In Resource Group `${AZ_RESOURCE_GROUP}`

Audit SAS keys and RBAC assignments for security best practices

- **Robot task name**: <code>Check Security Configuration for Service Bus `${SB_NAMESPACE_NAME}` In Resource Group `${AZ_RESOURCE_GROUP}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `service_bus_security_audit.sh`
- **Tags**: `servicebus`, `security`, `rbac`, `access:read-only`, `data:config`
- **Reads**: `AZ_RESOURCE_GROUP`, `SB_NAMESPACE_NAME`
- **Writes**: `service_bus_security.json`, `service_bus_security_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Discover Related Resources for Service Bus `${SB_NAMESPACE_NAME}` In Resource Group `${AZ_RESOURCE_GROUP}`

Discover and map Azure resources related to the Service Bus namespace

- **Robot task name**: <code>Discover Related Resources for Service Bus `${SB_NAMESPACE_NAME}` In Resource Group `${AZ_RESOURCE_GROUP}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `service_bus_related_resources.sh`
- **Tags**: `servicebus`, `related-resources`, `mapping`, `access:read-only`, `data:config`
- **Reads**: `AZ_RESOURCE_GROUP`, `SB_NAMESPACE_NAME`
- **Writes**: `service_bus_related_resources.json`, `service_bus_related_resources_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Test Connectivity to Service Bus `${SB_NAMESPACE_NAME}` In Resource Group `${AZ_RESOURCE_GROUP}`

Test network connectivity to the Service Bus namespace

- **Robot task name**: <code>Test Connectivity to Service Bus `${SB_NAMESPACE_NAME}` In Resource Group `${AZ_RESOURCE_GROUP}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `service_bus_connectivity_test.sh`
- **Tags**: `servicebus`, `connectivity`, `network`, `access:read-only`, `data:config`
- **Reads**: `AZ_RESOURCE_GROUP`, `SB_NAMESPACE_NAME`
- **Writes**: `service_bus_connectivity.json`, `service_bus_connectivity_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Check Azure Monitor Alerts for Service Bus `${SB_NAMESPACE_NAME}` In Resource Group `${AZ_RESOURCE_GROUP}`

Check for the presence and configuration of Azure Monitor alerts

- **Robot task name**: <code>Check Azure Monitor Alerts for Service Bus `${SB_NAMESPACE_NAME}` In Resource Group `${AZ_RESOURCE_GROUP}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `service_bus_alerts_check.sh`
- **Tags**: `servicebus`, `alerts`, `monitoring`, `access:read-only`, `data:config`
- **Reads**: `AZ_RESOURCE_GROUP`, `SB_NAMESPACE_NAME`
- **Writes**: `service_bus_alerts.json`, `service_bus_alerts_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


## Monitor

Performs a health check on Azure Service Bus instances and the components using them, generating a report of issues and next steps.

- **Robot file**: `sli.robot`
- **Score range**: `0.0` (failing) to `1.0` (healthy)
- **Aggregation**: arithmetic mean of the sub-checks below
- **Recommended interval**: `180s`

### Sub-checks

#### Check for Resource Health Issues Service Bus `${SB_NAMESPACE_NAME}` In Resource Group `${AZ_RESOURCE_GROUP}`

Fetch a list of issues that might affect the service bus instance

- **Robot task name**: <code>Check for Resource Health Issues Service Bus `${SB_NAMESPACE_NAME}` In Resource Group `${AZ_RESOURCE_GROUP}`</code>
- **Sub-metric name**: `resource_health`
- **Underlying script**: `service_bus_resource_health.sh`
- **Tags**: `azure`, `servicebus`, `resourcehealth`, `access:read-only`, `data:config`
- **Reads**: —
- **Pass condition**: `"${sb_health_output_list["properties"]["title"]}" == "Available"`


#### Check Basic Connectivity for Service Bus `${SB_NAMESPACE_NAME}`

Quick connectivity test to detect network issues

- **Robot task name**: <code>Check Basic Connectivity for Service Bus `${SB_NAMESPACE_NAME}`</code>
- **Sub-metric name**: `connectivity`
- **Underlying script**: `service_bus_connectivity_test.sh`
- **Tags**: `azure`, `servicebus`, `connectivity`, `access:read-only`, `data:config`
- **Reads**: —


#### Check Critical Metrics for Service Bus `${SB_NAMESPACE_NAME}`

Quick check of critical metrics that indicate immediate issues

- **Robot task name**: <code>Check Critical Metrics for Service Bus `${SB_NAMESPACE_NAME}`</code>
- **Sub-metric name**: `critical_metrics`
- **Underlying script**: `service_bus_metrics.sh`
- **Tags**: `azure`, `servicebus`, `metrics`, `access:read-only`, `data:config`
- **Reads**: —


## Inputs

| Name | Type | Description | Default | Required |
|---|---|---|---|---|
| `AZ_RESOURCE_GROUP` | string | The resource group to perform actions against. | — | yes |
| `SB_NAMESPACE_NAME` | string | The Azure Service Bus to health check. | — | yes |
| `AZURE_RESOURCE_SUBSCRIPTION_ID` | string | The Azure Subscription ID for the resource. | `""` | no |
| `ACTIVE_MESSAGE_THRESHOLD` | string | Threshold for active message count alerts (default: 1000) | `1000` | no |
| `DEAD_LETTER_THRESHOLD` | string | Threshold for dead letter message count alerts (default: 100) | `100` | no |
| `SIZE_PERCENTAGE_THRESHOLD` | string | Size percentage threshold for namespace/queue/topic alerts (default: 80) | `80` | no |
| `LATENCY_THRESHOLD_MS` | string | Latency threshold in milliseconds for connectivity alerts (default: 100) | `100` | no |

## Secrets

_No secrets imported in Robot source._

## Outputs

- Monitor health score (`0.0`–`1.0`) pushed by `sli.robot`
- `service_bus_health.json`
- `service_bus_config_health.json`
- `service_bus_metrics.json`
- `service_bus_metrics_issues.json`
- `service_bus_queues.json`
- `service_bus_queue_issues.json`
- `service_bus_topics.json`
- `service_bus_topic_issues.json`
- `service_bus_logs.json`
- `service_bus_log_issues.json`
- `service_bus_capacity.json`
- `service_bus_capacity_issues.json`
- `service_bus_dr.json`
- `service_bus_dr_issues.json`
- `service_bus_security.json`
- `service_bus_security_issues.json`
- `service_bus_related_resources.json`
- `service_bus_related_resources_issues.json`
- `service_bus_connectivity.json`
- `service_bus_connectivity_issues.json`
- `service_bus_alerts.json`
- `service_bus_alerts_issues.json`

## How to invoke

### Production (RunWhen runner / worker)

The platform **runner** schedules work on a location **worker**. The worker
image (`rw-base-runtime`) executes Robot via `runrobot.sh` with
`RW_PATH_TO_ROBOT` set to the bound path under `/home/runwhen/collection/`.

- **Runbook**: `codebundles/azure-servicebus-health/runbook.robot`
- **Monitor**: `codebundles/azure-servicebus-health/sli.robot`

### Local development (devcontainer only)

`ro` is a dev-time wrapper in `codecollection-devtools` — not the enterprise runtime.

```bash
cd codebundles/azure-servicebus-health
export AZ_RESOURCE_GROUP=...
export SB_NAMESPACE_NAME=...
export AZURE_RESOURCE_SUBSCRIPTION_ID=...
export ACTIVE_MESSAGE_THRESHOLD=...
export DEAD_LETTER_THRESHOLD=...
export SIZE_PERCENTAGE_THRESHOLD=...
ro runbook.robot
```

### Standalone scripts (no Robot)


Set the input variables above, then run the matching script:

```bash
cd codebundles/azure-servicebus-health
export AZ_RESOURCE_GROUP=...
export SB_NAMESPACE_NAME=...
export AZURE_RESOURCE_SUBSCRIPTION_ID=...
export ACTIVE_MESSAGE_THRESHOLD=...
bash service_bus_alerts_check.sh
bash service_bus_capacity.sh
bash service_bus_config_health.sh
bash service_bus_connectivity_test.sh
bash service_bus_disaster_recovery.sh
bash service_bus_log_analytics.sh
bash service_bus_metrics.sh
bash service_bus_queue_health.sh
bash service_bus_related_resources.sh
bash service_bus_resource_health.sh
bash service_bus_security_audit.sh
bash service_bus_topic_health.sh
```

## Source files

- `runbook.robot` — orchestrates tools and raises issues
- `sli.robot` — monitor scoring (`sli.robot` runtime file)
- `service_bus_alerts_check.sh` — Bash helper script `service_bus_alerts_check.sh`.
- `service_bus_capacity.sh` — Bash helper script `service_bus_capacity.sh`.
- `service_bus_config_health.sh` — Bash helper script `service_bus_config_health.sh`.
- `service_bus_connectivity_test.sh` — Bash helper script `service_bus_connectivity_test.sh`.
- `service_bus_disaster_recovery.sh` — Bash helper script `service_bus_disaster_recovery.sh`.
- `service_bus_log_analytics.sh` — Bash helper script `service_bus_log_analytics.sh`.
- `service_bus_metrics.sh` — Bash helper script `service_bus_metrics.sh`.
- `service_bus_queue_health.sh` — Bash helper script `service_bus_queue_health.sh`.
- `service_bus_related_resources.sh` — Bash helper script `service_bus_related_resources.sh`.
- `service_bus_resource_health.sh` — Bash helper script `service_bus_resource_health.sh`.
- `service_bus_security_audit.sh` — Bash helper script `service_bus_security_audit.sh`.
- `service_bus_topic_health.sh` — Bash helper script `service_bus_topic_health.sh`.
