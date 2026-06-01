---
name: azure-appservice-functionapp-health
kind: skill-template
description: Triages an Azure Function App and its workloads, checking its status and logs and verifying key metrics. Use when triaging or monitoring Azure, AppService, Health workloads with skill template `azu...
runtime:
  runbook: runbook.robot
  monitor: sli.robot
  runner: ro
platforms: [Azure, AppService, Health]
resource_types: [app_service]
access: read-only
---

# Azure Function App Health

## Summary

Checks key Function App metrics, individual function invocations, service plan utilization, fetches logs, config and activities for the service and generates a report of present issues for any found.

See [README.md](README.md) for additional context.

## Tools

### Check for Resource Health Issues Affecting Function App `${FUNCTION_APP_NAME}` In Resource Group `${AZ_RESOURCE_GROUP}`

Fetch a list of issues that might affect the Function App as reported from Azure.

- **Robot task name**: <code>Check for Resource Health Issues Affecting Function App `${FUNCTION_APP_NAME}` In Resource Group `${AZ_RESOURCE_GROUP}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `appservice_resource_health.sh`
- **Tags**: `aks`, `resource`, `health`, `service`, `azure`, `access:read-only`, `data:config`
- **Reads**: `AZ_RESOURCE_GROUP`, `FUNCTION_APP_NAME`
- **Writes**: `function_app_health.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Analyze Function Failure Patterns for Function App `${FUNCTION_APP_NAME}` In Resource Group `${AZ_RESOURCE_GROUP}`

Enhanced failure pattern analysis with temporal correlation and structured data collection.

- **Robot task name**: <code>Analyze Function Failure Patterns for Function App `${FUNCTION_APP_NAME}` In Resource Group `${AZ_RESOURCE_GROUP}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `function_failure_analysis.sh`
- **Tags**: `access:read-only`, `functionapp`, `failure-analysis`, `pattern-analysis`, `enhanced`, `data:logs-regexp`
- **Reads**: —
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Check Function App `${FUNCTION_APP_NAME}` Health in Resource Group `${AZ_RESOURCE_GROUP}`

Checks the health status of a appservice workload.

- **Robot task name**: <code>Check Function App `${FUNCTION_APP_NAME}` Health in Resource Group `${AZ_RESOURCE_GROUP}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `appservice_health_metric.sh`
- **Tags**: `access:read-only`, `appservice`, `health`, `data:config`
- **Reads**: `AZ_RESOURCE_GROUP`, `FUNCTION_APP_NAME`
- **Writes**: `function_app_health_check_metrics.json`, `function_app_health_check_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Fetch Function App `${FUNCTION_APP_NAME}` Plan Utilization Metrics In Resource Group `${AZ_RESOURCE_GROUP}`

Reviews key metrics for the Function App plan and generates a report

- **Robot task name**: <code>Fetch Function App `${FUNCTION_APP_NAME}` Plan Utilization Metrics In Resource Group `${AZ_RESOURCE_GROUP}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `appservice_plan_utilization_health.sh`
- **Tags**: `access:read-only`, `appservice`, `utilization`, `data:config`
- **Reads**: `AZ_RESOURCE_GROUP`, `FUNCTION_APP_NAME`
- **Writes**: `function_app_plan_metrics.json`, `function_app_plan_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Check Individual Function Invocations Health for Function App `${FUNCTION_APP_NAME}` In Resource Group `${AZ_RESOURCE_GROUP}`

Analyzes the health and metrics of individual function invocations, including execution counts, errors, throttles, and performance metrics.

- **Robot task name**: <code>Check Individual Function Invocations Health for Function App `${FUNCTION_APP_NAME}` In Resource Group `${AZ_RESOURCE_GROUP}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `function_invocation_health.sh`
- **Tags**: `access:read-only`, `functionapp`, `functions`, `invocations`, `metrics`, `performance`, `data:config`
- **Reads**: `AZ_RESOURCE_GROUP`, `FUNCTION_APP_NAME`
- **Writes**: `function_invocation_health.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Get Function App `${FUNCTION_APP_NAME}` Logs and Analyze Errors In Resource Group `${AZ_RESOURCE_GROUP}`

Fetch logs of appservice workload and analyze for errors

- **Robot task name**: <code>Get Function App `${FUNCTION_APP_NAME}` Logs and Analyze Errors In Resource Group `${AZ_RESOURCE_GROUP}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `appservice_logs.sh`
- **Tags**: `appservice`, `logs`, `analysis`, `access:read-only`, `data:logs-regexp`
- **Reads**: `AZ_RESOURCE_GROUP`, `FUNCTION_APP_NAME`
- **Writes**: `function_app_log_issues_report.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Check Configuration Health of Function App `${FUNCTION_APP_NAME}` In Resource Group `${AZ_RESOURCE_GROUP}`

Fetch the configuration health of the Function App

- **Robot task name**: <code>Check Configuration Health of Function App `${FUNCTION_APP_NAME}` In Resource Group `${AZ_RESOURCE_GROUP}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `appservice_config_health.sh`
- **Tags**: `appservice`, `logs`, `tail`, `access:read-only`, `data:config`
- **Reads**: `AZ_RESOURCE_GROUP`, `FUNCTION_APP_NAME`
- **Writes**: `az_function_app_config_health.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Check Deployment Health of Function App `${FUNCTION_APP_NAME}` In Resource Group `${AZ_RESOURCE_GROUP}`

Fetch deployment health of the Function App

- **Robot task name**: <code>Check Deployment Health of Function App `${FUNCTION_APP_NAME}` In Resource Group `${AZ_RESOURCE_GROUP}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `appservice_deployment_health.sh`
- **Tags**: `appservice`, `deployment`, `access:read-only`, `data:config`
- **Reads**: `AZ_RESOURCE_GROUP`, `FUNCTION_APP_NAME`
- **Writes**: `deployment_health.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Fetch Function App `${FUNCTION_APP_NAME}` Activities In Resource Group `${AZ_RESOURCE_GROUP}`

Gets the events of function app and checks for start/stop operations and errors

- **Robot task name**: <code>Fetch Function App `${FUNCTION_APP_NAME}` Activities In Resource Group `${AZ_RESOURCE_GROUP}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `functionapp_activities.sh`
- **Tags**: `appservice`, `monitor`, `events`, `errors`, `access:read-only`, `data:logs-bulk`
- **Reads**: `AZ_RESOURCE_GROUP`, `FUNCTION_APP_NAME`
- **Writes**: `function_app_activities_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Fetch Azure Recommendations and Notifications for Function App `${FUNCTION_APP_NAME}` In Resource Group `${AZ_RESOURCE_GROUP}`

Fetch Azure Advisor recommendations, Service Health notifications, and security assessments for the Function App

- **Robot task name**: <code>Fetch Azure Recommendations and Notifications for Function App `${FUNCTION_APP_NAME}` In Resource Group `${AZ_RESOURCE_GROUP}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `appservice_recommendations.sh`
- **Tags**: `appservice`, `recommendations`, `advisor`, `notifications`, `access:read-only`, `data:config`
- **Reads**: `AZ_RESOURCE_GROUP`, `FUNCTION_APP_NAME`
- **Writes**: `function_app_recommendations_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Check Recent Activities for Function App `${FUNCTION_APP_NAME}` In Resource Group `${AZ_RESOURCE_GROUP}`

Analyze recent Azure activities for the Function App, including critical operations and user actions.

- **Robot task name**: <code>Check Recent Activities for Function App `${FUNCTION_APP_NAME}` In Resource Group `${AZ_RESOURCE_GROUP}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `functionapp_activities.sh`
- **Tags**: `access:read-only`, `functionapp`, `activities`, `audit`, `data:logs-bulk`
- **Reads**: `AZ_RESOURCE_GROUP`, `FUNCTION_APP_NAME`
- **Writes**: `function_app_activities_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Check Diagnostic Logs for Function App `${FUNCTION_APP_NAME}` In Resource Group `${AZ_RESOURCE_GROUP}`

Check for diagnostic logs configuration and search them for relevant events if they exist.

- **Robot task name**: <code>Check Diagnostic Logs for Function App `${FUNCTION_APP_NAME}` In Resource Group `${AZ_RESOURCE_GROUP}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `functionapp_diagnostic_logs.sh`
- **Tags**: `access:read-only`, `functionapp`, `diagnostic-logs`, `monitoring`, `data:logs-regexp`
- **Reads**: `AZ_RESOURCE_GROUP`, `FUNCTION_APP_NAME`
- **Writes**: `functionapp_diagnostic_logs.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


## Monitor

Queries the health status of an Function App, and returns 0 when it's not healthy, and 1 when it is.

- **Robot file**: `sli.robot`
- **Score range**: `0.0` (failing) to `1.0` (healthy)
- **Aggregation**: arithmetic mean of the sub-checks below
- **Recommended interval**: `180s`

### Sub-checks

#### Check for Resource Health Issues Affecting Function App `${FUNCTION_APP_NAME}` In Resource Group `${AZ_RESOURCE_GROUP}`

Fetch a list of issues that might affect the Function App as reported from Azure.

- **Robot task name**: <code>Check for Resource Health Issues Affecting Function App `${FUNCTION_APP_NAME}` In Resource Group `${AZ_RESOURCE_GROUP}`</code>
- **Sub-metric name**: `resource_health`
- **Underlying script**: `appservice_resource_health.sh`
- **Tags**: `aks`, `resource`, `health`, `service`, `azure`, `data:config`
- **Reads**: —
- **Pass condition**: `"${resource_health_output_json["properties"]["title"]}" == "Available"`


#### Check Function App `${FUNCTION_APP_NAME}` Health Check Metrics In Resource Group `${AZ_RESOURCE_GROUP}`

Checks the health check metric of a appservice workload. If issues are generated with severity 1 or 2, the score is 0 / unhealthy.

- **Robot task name**: <code>Check Function App `${FUNCTION_APP_NAME}` Health Check Metrics In Resource Group `${AZ_RESOURCE_GROUP}`</code>
- **Sub-metric name**: `health_checks`
- **Underlying script**: `appservice_health_metric.sh`
- **Tags**: `healthcheck`, `metric`, `appservice`, `data:config`
- **Reads**: —


#### Check Function App `${FUNCTION_APP_NAME}` Configuration Health In Resource Group `${AZ_RESOURCE_GROUP}`

Checks the configuration health of a appservice workload. 1 = healthy, 0 = unhealthy.

- **Robot task name**: <code>Check Function App `${FUNCTION_APP_NAME}` Configuration Health In Resource Group `${AZ_RESOURCE_GROUP}`</code>
- **Sub-metric name**: `configuration`
- **Underlying script**: `appservice_config_health.sh`
- **Tags**: `appservice`, `configuration`, `health`, `data:config`
- **Reads**: —


#### Check Deployment Health of Function App `${FUNCTION_APP_NAME}` In Resource Group `${AZ_RESOURCE_GROUP}`

Fetch deployment health of the Function App

- **Robot task name**: <code>Check Deployment Health of Function App `${FUNCTION_APP_NAME}` In Resource Group `${AZ_RESOURCE_GROUP}`</code>
- **Sub-metric name**: `deployment_health`
- **Underlying script**: `appservice_deployment_health.sh`
- **Tags**: `appservice`, `deployment`, `data:config`
- **Reads**: —


#### Fetch Function App `${FUNCTION_APP_NAME}` Activities In Resource Group `${AZ_RESOURCE_GROUP}`

Gets the events of appservice and checks for errors

- **Robot task name**: <code>Fetch Function App `${FUNCTION_APP_NAME}` Activities In Resource Group `${AZ_RESOURCE_GROUP}`</code>
- **Sub-metric name**: `activities`
- **Underlying script**: `appservice_activities.sh`
- **Tags**: `appservice`, `monitor`, `events`, `errors`, `data:logs-bulk`
- **Reads**: —


## Inputs

| Name | Type | Description | Default | Required |
|---|---|---|---|---|
| `AZ_RESOURCE_GROUP` | string | The resource group to perform actions against. | — | yes |
| `FUNCTION_APP_NAME` | string | The Azure AppService to triage. | — | yes |
| `AZURE_RESOURCE_SUBSCRIPTION_ID` | string | The Azure Subscription ID for the resource. | `""` | no |
| `RW_LOOKBACK_WINDOW` | string | The time period, in minutes, to look back for activites/events. | `10` | no |
| `TIME_PERIOD_DAYS` | string | The time period, in days, to look back for recommendations and notifications. | `7` | no |
| `CPU_THRESHOLD` | string | The CPU % threshold in which to generate an issue. | `80` | no |
| `REQUESTS_THRESHOLD` | string | The threshold of requests/s in which to generate an issue. | `1000` | no |
| `BYTES_RECEIVED_THRESHOLD` | string | The threshold of received bytes/s in which to generate an issue. | `10485760` | no |
| `HTTP5XX_THRESHOLD` | string | The threshold of HTTP5XX/s in which to generate an issue. Higher than this value indicates a high error rate. | `5` | no |
| `HTTP2XX_THRESHOLD` | string | The threshold of HTTP2XX/s in which to generate an issue. Less than this value indicates low success rate. | `50` | no |
| `HTTP4XX_THRESHOLD` | string | The threshold of HTTP4XX/s in which to generate an issue. Higher than this value indicates high client error rate. | `200` | no |
| `DISK_USAGE_THRESHOLD` | string | The threshold of disk usage % in which to generate an issue. | `90` | no |
| `AVG_RSP_TIME` | string | The threshold of average response time (ms) in which to generate an issue. Higher than this value indicates slow response time. | `300` | no |
| `FUNCTION_ERROR_RATE_THRESHOLD` | string | The threshold of function error rate (%) in which to generate an issue. Higher than this value indicates high function error rate. | `10` | no |
| `FUNCTION_MEMORY_THRESHOLD` | string | The threshold of function memory usage (MB) in which to generate an issue. Higher than this value indicates high memory usage. | `512` | no |
| `FUNCTION_DURATION_THRESHOLD` | string | The threshold of function execution duration (ms) in which to generate an issue. Higher than this value indicates slow function execution. | `5000` | no |
| `EXECUTION_UNITS_COST_THRESHOLD` | string | Static threshold for execution units cost alerts - represents ~$500/month at default (default: 10000000) | `10000000` | no |
| `EXECUTION_UNITS_ANOMALY_MULTIPLIER` | string | Multiplier for anomaly detection - alerts when execution units are X times higher than baseline (default: 5) | `5` | no |
| `BASELINE_LOOKBACK_DAYS` | string | Number of days to look back for baseline calculation (default: 7) | `7` | no |
| `AZURE_SUBSCRIPTION_NAME` | string | The friendly name of the subscription ID. | `subscription-01` | no |

## Secrets

_No secrets imported in Robot source._

## Outputs

- Monitor health score (`0.0`–`1.0`) pushed by `sli.robot`
- `function_app_health.json`
- `function_app_health_check_metrics.json`
- `function_app_health_check_issues.json`
- `function_app_plan_metrics.json`
- `function_app_plan_issues.json`
- `function_invocation_health.json`
- `function_app_log_issues_report.json`
- `az_function_app_config_health.json`
- `deployment_health.json`
- `function_app_activities_issues.json`
- `function_app_recommendations_issues.json`
- `functionapp_diagnostic_logs.json`

## How to invoke

### Preferred: Robot Framework runner (`ro`)

```bash
cd codebundles/azure-appservice-functionapp-health
export AZ_RESOURCE_GROUP=...
export FUNCTION_APP_NAME=...
export AZURE_RESOURCE_SUBSCRIPTION_ID=...
export RW_LOOKBACK_WINDOW=...
export TIME_PERIOD_DAYS=...
export CPU_THRESHOLD=...
ro runbook.robot
```

### Standalone scripts (no Robot)


Set the input variables above, then run the matching script:

```bash
cd codebundles/azure-appservice-functionapp-health
export AZ_RESOURCE_GROUP=...
export FUNCTION_APP_NAME=...
export AZURE_RESOURCE_SUBSCRIPTION_ID=...
export RW_LOOKBACK_WINDOW=...
bash appservice_activities.sh
bash appservice_activities_enhanced.sh
bash appservice_config_health.sh
bash appservice_deployment_health.sh
bash appservice_health_metric.sh
bash appservice_logs.sh
bash appservice_plan_utilization_health.sh
bash appservice_recommendations.sh
bash appservice_recommendations_enhanced.sh
bash appservice_resource_health.sh
bash function_failure_analysis.sh
bash function_invocation_health.sh
# ... and 3 more scripts
```

## Source files

- `runbook.robot` — orchestrates tools and raises issues
- `sli.robot` — monitor scoring (`sli.robot` runtime file)
- `appservice_activities.sh` — Bash helper script `appservice_activities.sh`.
- `appservice_activities_enhanced.sh` — Bash helper script `appservice_activities_enhanced.sh`.
- `appservice_config_health.sh` — Bash helper script `appservice_config_health.sh`.
- `appservice_deployment_health.sh` — Bash helper script `appservice_deployment_health.sh`.
- `appservice_health_metric.sh` — Bash helper script `appservice_health_metric.sh`.
- `appservice_logs.sh` — Bash helper script `appservice_logs.sh`.
- `appservice_plan_utilization_health.sh` — Bash helper script `appservice_plan_utilization_health.sh`.
- `appservice_recommendations.sh` — Bash helper script `appservice_recommendations.sh`.
- `appservice_recommendations_enhanced.sh` — Bash helper script `appservice_recommendations_enhanced.sh`.
- `appservice_resource_health.sh` — Bash helper script `appservice_resource_health.sh`.
- `function_failure_analysis.sh` — Bash helper script `function_failure_analysis.sh`.
- `function_invocation_health.sh` — Bash helper script `function_invocation_health.sh`.
- `function_invocation_logger.sh` — Bash helper script `function_invocation_logger.sh`.
- `functionapp_activities.sh` — Bash helper script `functionapp_activities.sh`.
- `functionapp_diagnostic_logs.sh` — Bash helper script `functionapp_diagnostic_logs.sh`.
