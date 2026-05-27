---
name: azure-appservice-webapp-health
description: Triages an Azure App Service and its workloads, checking its status and logs and verifying key metrics. Use when triaging or monitoring Azure, AppService, Triage workloads with skill template `azur...
runtime:
  runbook: runbook.robot
  monitor: sli.robot
  runner: ro
platforms: [Azure, AppService, Triage]
resource_types: [app_service]
access: read-only
---

# Azure App Service Webapp Health

## Summary

Checks key App Service metrics and the service plan, fetches logs, config and activities for the service and generates a report of present issues for any found.

See [README.md](README.md) for additional context.

## Tools

### Check for Resource Health Issues Affecting App Service `${APP_SERVICE_NAME}` In Resource Group `${AZ_RESOURCE_GROUP}`

Fetch a list of issues that might affect the APP Service as reported from Azure.

- **Robot task name**: <code>Check for Resource Health Issues Affecting App Service `${APP_SERVICE_NAME}` In Resource Group `${AZ_RESOURCE_GROUP}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `appservice_resource_health.sh`
- **Tags**: `aks`, `resource`, `health`, `service`, `azure`, `access:read-only`, `data:config`
- **Reads**: `APP_SERVICE_NAME`, `AZ_RESOURCE_GROUP`
- **Writes**: `app_service_health.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Check App Service `${APP_SERVICE_NAME}` Health in Resource Group `${AZ_RESOURCE_GROUP}`

Checks the health status of a appservice workload.

- **Robot task name**: <code>Check App Service `${APP_SERVICE_NAME}` Health in Resource Group `${AZ_RESOURCE_GROUP}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `appservice_health_metric.sh`
- **Tags**: `access:read-only`, `appservice`, `health`, `data:config`
- **Reads**: `APP_SERVICE_NAME`, `AZ_RESOURCE_GROUP`
- **Writes**: `app_service_health_check_metrics.json`, `app_service_health_check_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Fetch App Service `${APP_SERVICE_NAME}` Utilization Metrics In Resource Group `${AZ_RESOURCE_GROUP}`

Reviews all key metrics (CPU, Requests, Bandwidth, HTTP status codes, Threads, Disk, Response Time) for the last 30 minutes with 5-minute intervals

- **Robot task name**: <code>Fetch App Service `${APP_SERVICE_NAME}` Utilization Metrics In Resource Group `${AZ_RESOURCE_GROUP}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `appservice_metric_health.sh`
- **Tags**: `access:read-only`, `appservice`, `utilization`, `metrics`, `data:config`
- **Reads**: `APP_SERVICE_NAME`, `AZ_RESOURCE_GROUP`
- **Writes**: `app_service_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Get App Service `${APP_SERVICE_NAME}` Logs In Resource Group `${AZ_RESOURCE_GROUP}`

Download and display recent raw log files from App Service (last 50 lines from each log file)

- **Robot task name**: <code>Get App Service `${APP_SERVICE_NAME}` Logs In Resource Group `${AZ_RESOURCE_GROUP}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `appservice_logs.sh`
- **Tags**: `appservice`, `logs`, `display`, `raw`, `access:read-only`, `data:logs-bulk`
- **Reads**: `APP_SERVICE_NAME`, `AZ_RESOURCE_GROUP`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Check Configuration Health of App Service `${APP_SERVICE_NAME}` In Resource Group `${AZ_RESOURCE_GROUP}`

Fetch the configuration health of the App Service

- **Robot task name**: <code>Check Configuration Health of App Service `${APP_SERVICE_NAME}` In Resource Group `${AZ_RESOURCE_GROUP}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `appservice_config_health.sh`
- **Tags**: `appservice`, `logs`, `tail`, `access:read-only`, `data:config`
- **Reads**: `APP_SERVICE_NAME`, `AZ_RESOURCE_GROUP`
- **Writes**: `az_app_service_health.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Check Deployment Health of App Service `${APP_SERVICE_NAME}` In Resource Group `${AZ_RESOURCE_GROUP}`

Fetch deployment health of the App Service

- **Robot task name**: <code>Check Deployment Health of App Service `${APP_SERVICE_NAME}` In Resource Group `${AZ_RESOURCE_GROUP}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `appservice_deployment_health.sh`
- **Tags**: `appservice`, `deployment`, `access:read-only`, `data:config`
- **Reads**: `APP_SERVICE_NAME`, `AZ_RESOURCE_GROUP`
- **Writes**: `deployment_health.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Fetch App Service `${APP_SERVICE_NAME}` Activities In Resource Group `${AZ_RESOURCE_GROUP}`

Gets the events of appservice and checks for errors

- **Robot task name**: <code>Fetch App Service `${APP_SERVICE_NAME}` Activities In Resource Group `${AZ_RESOURCE_GROUP}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `appservice_activities.sh`
- **Tags**: `appservice`, `monitor`, `events`, `errors`, `access:read-only`, `data:logs-bulk`
- **Reads**: `APP_SERVICE_NAME`, `AZ_RESOURCE_GROUP`
- **Writes**: `app_service_activities_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Check Recent Activities for App Service `${APP_SERVICE_NAME}` In Resource Group `${AZ_RESOURCE_GROUP}`

Analyze recent Azure activities for the App Service, including critical operations and user actions.

- **Robot task name**: <code>Check Recent Activities for App Service `${APP_SERVICE_NAME}` In Resource Group `${AZ_RESOURCE_GROUP}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `appservice_activities_enhanced.sh`
- **Tags**: `access:read-only`, `appservice`, `activities`, `audit`, `data:logs-bulk`
- **Reads**: `APP_SERVICE_NAME`, `AZ_RESOURCE_GROUP`
- **Writes**: `app_service_activities_enhanced.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Check Recommendations and Notifications for App Service `${APP_SERVICE_NAME}` In Resource Group `${AZ_RESOURCE_GROUP}`

Fetch Azure Advisor, Service Health, and Security Center recommendations for the App Service.

- **Robot task name**: <code>Check Recommendations and Notifications for App Service `${APP_SERVICE_NAME}` In Resource Group `${AZ_RESOURCE_GROUP}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `appservice_recommendations.sh`
- **Tags**: `access:read-only`, `appservice`, `recommendations`, `notifications`, `data:config`
- **Reads**: `APP_SERVICE_NAME`, `AZURE_SUBSCRIPTION_NAME`, `AZ_RESOURCE_GROUP`
- **Writes**: `app_service_recommendations.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Check Diagnostic Logs for App Service `${APP_SERVICE_NAME}` In Resource Group `${AZ_RESOURCE_GROUP}`

Check diagnostic settings, query Log Analytics and Application Insights for errors and failed requests

- **Robot task name**: <code>Check Diagnostic Logs for App Service `${APP_SERVICE_NAME}` In Resource Group `${AZ_RESOURCE_GROUP}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `appservice_diagnostic_logs.sh`
- **Tags**: `appservice`, `logs`, `diagnostics`, `analysis`, `azure-monitor`, `access:read-only`, `data:logs-regexp`
- **Reads**: `APP_SERVICE_NAME`, `AZ_RESOURCE_GROUP`
- **Writes**: `app_service_diagnostic_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Check Logs for Errors in App Service `${APP_SERVICE_NAME}` In Resource Group `${AZ_RESOURCE_GROUP}`

Analyze App Service logs for errors using Azure Monitor APIs and Application Insights - creates structured issues for detected problems

- **Robot task name**: <code>Check Logs for Errors in App Service `${APP_SERVICE_NAME}` In Resource Group `${AZ_RESOURCE_GROUP}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `appservice_log_analysis.sh`
- **Tags**: `appservice`, `logs`, `errors`, `analysis`, `azure-monitor`, `access:read-only`, `data:logs-regexp`
- **Reads**: `APP_SERVICE_NAME`, `AZ_RESOURCE_GROUP`
- **Writes**: `app_service_log_issues_report.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


## Monitor

Queries the health status of an App Service, and returns 0 when it's not healthy, and 1 when it is.

- **Robot file**: `sli.robot`
- **Score range**: `0.0` (failing) to `1.0` (healthy)
- **Aggregation**: arithmetic mean of the sub-checks below
- **Recommended interval**: `180s`

### Sub-checks

#### Check for Resource Health Issues Affecting App Service `${APP_SERVICE_NAME}` In Resource Group `${AZ_RESOURCE_GROUP}`

Fetch a list of issues that might affect the APP Service as reported from Azure.

- **Robot task name**: <code>Check for Resource Health Issues Affecting App Service `${APP_SERVICE_NAME}` In Resource Group `${AZ_RESOURCE_GROUP}`</code>
- **Sub-metric name**: `resource_health`
- **Underlying script**: `appservice_resource_health.sh`
- **Tags**: `aks`, `resource`, `health`, `service`, `azure`, `data:config`
- **Reads**: `APP_SERVICE_RUNNING`
- **Pass condition**: `"${resource_health_output_json["properties"]["title"]}" == "Available"`


#### Check App Service `${APP_SERVICE_NAME}` Health Check Metrics In Resource Group `${AZ_RESOURCE_GROUP}`

Checks the health check metric of a appservice workload. If issues are generated with severity 1 or 2, the score is 0 / unhealthy.

- **Robot task name**: <code>Check App Service `${APP_SERVICE_NAME}` Health Check Metrics In Resource Group `${AZ_RESOURCE_GROUP}`</code>
- **Sub-metric name**: `health_checks`
- **Underlying script**: `appservice_health_metric.sh`
- **Tags**: `healthcheck`, `metric`, `appservice`, `data:config`
- **Reads**: `APP_SERVICE_RUNNING`


#### Check App Service `${APP_SERVICE_NAME}` Configuration Health In Resource Group `${AZ_RESOURCE_GROUP}`

Checks the configuration health of a appservice workload. 1 = healthy, 0 = unhealthy.

- **Robot task name**: <code>Check App Service `${APP_SERVICE_NAME}` Configuration Health In Resource Group `${AZ_RESOURCE_GROUP}`</code>
- **Sub-metric name**: `configuration`
- **Underlying script**: `appservice_config_health.sh`
- **Tags**: `appservice`, `configuration`, `health`, `data:config`
- **Reads**: `APP_SERVICE_RUNNING`


#### Check Deployment Health of App Service `${APP_SERVICE_NAME}` In Resource Group `${AZ_RESOURCE_GROUP}`

Fetch deployment health of the App Service

- **Robot task name**: <code>Check Deployment Health of App Service `${APP_SERVICE_NAME}` In Resource Group `${AZ_RESOURCE_GROUP}`</code>
- **Sub-metric name**: `deployment_health`
- **Underlying script**: `appservice_deployment_health.sh`
- **Tags**: `appservice`, `deployment`, `data:config`
- **Reads**: `APP_SERVICE_RUNNING`


#### Fetch App Service `${APP_SERVICE_NAME}` Activities In Resource Group `${AZ_RESOURCE_GROUP}`

Gets the events of appservice and checks for errors

- **Robot task name**: <code>Fetch App Service `${APP_SERVICE_NAME}` Activities In Resource Group `${AZ_RESOURCE_GROUP}`</code>
- **Sub-metric name**: `activities`
- **Underlying script**: `appservice_activities.sh`
- **Tags**: `appservice`, `monitor`, `events`, `errors`, `data:logs-bulk`
- **Reads**: `APP_SERVICE_RUNNING`


## Inputs

| Name | Type | Description | Default | Required |
|---|---|---|---|---|
| `AZ_RESOURCE_GROUP` | string | The resource group to perform actions against. | — | yes |
| `APP_SERVICE_NAME` | string | The Azure AppService to triage. | — | yes |
| `AZURE_RESOURCE_SUBSCRIPTION_ID` | string | The Azure Subscription ID for the resource. | `""` | no |
| `RW_LOOKBACK_WINDOW` | string | The time period, in minutes, to look back for activites/events. | `10` | no |
| `CPU_THRESHOLD` | string | The CPU % threshold in which to generate an issue. | `80` | no |
| `REQUESTS_THRESHOLD` | string | The threshold of requests/s in which to generate an issue. | `1000` | no |
| `BYTES_RECEIVED_THRESHOLD` | string | The threshold of received bytes/s in which to generate an issue. | `10485760` | no |
| `HTTP5XX_THRESHOLD` | string | The threshold of HTTP5XX/s in which to generate an issue. Higher than this value indicates a high error rate. | `5` | no |
| `HTTP2XX_THRESHOLD` | string | The threshold of HTTP2XX/s in which to generate an issue. Less than this value indicates low success rate. | `50` | no |
| `HTTP4XX_THRESHOLD` | string | The threshold of HTTP4XX/s in which to generate an issue. Higher than this value indicates high client error rate. | `200` | no |
| `DISK_USAGE_THRESHOLD` | string | The threshold of disk usage % in which to generate an issue. | `90` | no |
| `AVG_RSP_TIME` | string | The threshold of average response time (ms) in which to generate an issue. Higher than this value indicates slow response time. | `300` | no |
| `AZURE_SUBSCRIPTION_NAME` | string | The friendly name of the subscription ID. | `subscription-01` | no |

## Secrets

_No secrets imported in Robot source._

## Outputs

- Monitor health score (`0.0`–`1.0`) pushed by `sli.robot`
- `app_service_health.json`
- `app_service_health_check_metrics.json`
- `app_service_health_check_issues.json`
- `app_service_issues.json`
- `az_app_service_health.json`
- `deployment_health.json`
- `app_service_activities_issues.json`
- `app_service_activities_enhanced.json`
- `app_service_recommendations.json`
- `app_service_diagnostic_issues.json`
- `app_service_log_issues_report.json`

## How to invoke

### Preferred: Robot Framework runner (`ro`)

```bash
cd codebundles/azure-appservice-webapp-health
export AZ_RESOURCE_GROUP=...
export APP_SERVICE_NAME=...
export AZURE_RESOURCE_SUBSCRIPTION_ID=...
export RW_LOOKBACK_WINDOW=...
export CPU_THRESHOLD=...
export REQUESTS_THRESHOLD=...
ro runbook.robot
```

### Standalone scripts (no Robot)


Set the input variables above, then run the matching script:

```bash
cd codebundles/azure-appservice-webapp-health
export AZ_RESOURCE_GROUP=...
export APP_SERVICE_NAME=...
export AZURE_RESOURCE_SUBSCRIPTION_ID=...
export RW_LOOKBACK_WINDOW=...
bash appservice_activities.sh
bash appservice_activities_enhanced.sh
bash appservice_config_health.sh
bash appservice_deployment_health.sh
bash appservice_diagnostic_logs.sh
bash appservice_health_metric.sh
bash appservice_log_analysis.sh
bash appservice_logs.sh
bash appservice_metric_health.sh
bash appservice_recommendations.sh
bash appservice_resource_health.sh
```

## Source files

- `runbook.robot` — orchestrates tools and raises issues
- `sli.robot` — monitor scoring (`sli.robot` runtime file)
- `appservice_activities.sh` — Bash helper script `appservice_activities.sh`.
- `appservice_activities_enhanced.sh` — Bash helper script `appservice_activities_enhanced.sh`.
- `appservice_config_health.sh` — Bash helper script `appservice_config_health.sh`.
- `appservice_deployment_health.sh` — Bash helper script `appservice_deployment_health.sh`.
- `appservice_diagnostic_logs.sh` — Bash helper script `appservice_diagnostic_logs.sh`.
- `appservice_health_metric.sh` — Bash helper script `appservice_health_metric.sh`.
- `appservice_log_analysis.sh` — Bash helper script `appservice_log_analysis.sh`.
- `appservice_logs.sh` — Bash helper script `appservice_logs.sh`.
- `appservice_metric_health.sh` — Bash helper script `appservice_metric_health.sh`.
- `appservice_recommendations.sh` — Bash helper script `appservice_recommendations.sh`.
- `appservice_resource_health.sh` — Bash helper script `appservice_resource_health.sh`.
