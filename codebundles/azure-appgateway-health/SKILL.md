---
name: azure-appgateway-health
description: Performs a health check on Azure Application Gateways and the backend pools used by them, generating a report of... Use when triaging or monitoring Azure, Application, Gateway workloads with skill ...
runtime:
  runbook: runbook.robot
  monitor: sli.robot
  runner: ro
platforms: [Azure, Application, Gateway]
resource_types: [application_gateway]
access: read-only
---

# Azure Application Gateway Health

## Summary

Checks key metrics for Azure Application Gateways and queries the health status of backend pools used by the gateway.

See [README.md](README.md) for additional context.

## Tools

### Check for Resource Health Issues Affecting Application Gateway `${APP_GATEWAY_NAME}` In Resource Group `${AZ_RESOURCE_GROUP}`

Fetch a list of issues that might affect the application gateway cluster

- **Robot task name**: <code>Check for Resource Health Issues Affecting Application Gateway `${APP_GATEWAY_NAME}` In Resource Group `${AZ_RESOURCE_GROUP}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `app_gateway_resource_health.sh`
- **Tags**: `appgateway`, `resourcehealth`, `access:read-only`, `data:config`
- **Reads**: `APP_GATEWAY_NAME`, `AZ_RESOURCE_GROUP`
- **Writes**: `app_gateway_health.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Check Configuration Health of Application Gateway `${APP_GATEWAY_NAME}` In Resource Group `${AZ_RESOURCE_GROUP}`

Fetch the details and health of the application gateway configuration

- **Robot task name**: <code>Check Configuration Health of Application Gateway `${APP_GATEWAY_NAME}` In Resource Group `${AZ_RESOURCE_GROUP}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `app_gateway_config_health.sh`
- **Tags**: `appgateway`, `config`, `health`, `access:read-only`, `data:config`
- **Reads**: `APP_GATEWAY_NAME`, `AZ_RESOURCE_GROUP`
- **Writes**: `app_gateway_config_health.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Check Backend Pool Health for Application Gateway `${APP_GATEWAY_NAME}` In Resource Group `${AZ_RESOURCE_GROUP}`

Fetch the health of the application gateway backend pool members

- **Robot task name**: <code>Check Backend Pool Health for Application Gateway `${APP_GATEWAY_NAME}` In Resource Group `${AZ_RESOURCE_GROUP}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `app_gateway_backend_health.sh`
- **Tags**: `appgateway`, `logs`, `tail`, `access:read-only`, `data:config`
- **Reads**: `APP_GATEWAY_NAME`, `AZ_RESOURCE_GROUP`
- **Writes**: `backend_pool_members_health.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Fetch Log Analytics for Application Gateway `${APP_GATEWAY_NAME}` In Resource Group `${AZ_RESOURCE_GROUP}`

Fetch log analytics for the application gateway

- **Robot task name**: <code>Fetch Log Analytics for Application Gateway `${APP_GATEWAY_NAME}` In Resource Group `${AZ_RESOURCE_GROUP}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `app_gateway_log_analytics.sh`
- **Tags**: `access:read-only`, `appgateway`, `logs`, `analytics`, `uri_errors`, `requests`, `ssl`, `errors`, `data:logs-regexp`
- **Reads**: —
- **Writes**: `app_gateway_log_metrics.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Fetch Metrics for Application Gateway `${APP_GATEWAY_NAME}` In Resource Group `${AZ_RESOURCE_GROUP}`

Fetch metrics for the application gateway

- **Robot task name**: <code>Fetch Metrics for Application Gateway `${APP_GATEWAY_NAME}` In Resource Group `${AZ_RESOURCE_GROUP}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `app_gateway_metrics.sh`
- **Tags**: `access:read-only`, `appgateway`, `metrics`, `analytics`, `data:config`
- **Reads**: `APP_GATEWAY_NAME`, `AZ_RESOURCE_GROUP`
- **Writes**: `app_gateway_metrics.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Check SSL Certificate Health for Application Gateway `${APP_GATEWAY_NAME}` In Resource Group `${AZ_RESOURCE_GROUP}`

Fetch SSL certificates and validate expiry dates for Azure Application Gateway instances

- **Robot task name**: <code>Check SSL Certificate Health for Application Gateway `${APP_GATEWAY_NAME}` In Resource Group `${AZ_RESOURCE_GROUP}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `app_gateway_ssl_certs.sh`
- **Tags**: `access:read-only`, `appgateway`, `ssl`, `expiry`, `data:config`
- **Reads**: `APP_GATEWAY_NAME`, `AZ_RESOURCE_GROUP`
- **Writes**: `appgw_ssl_certificate_checks.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Check Logs for Errors with Application Gateway `${APP_GATEWAY_NAME}` In Resource Group `${AZ_RESOURCE_GROUP}`

Query log analytics workspace for common errors like IP mismatches or subnet issues

- **Robot task name**: <code>Check Logs for Errors with Application Gateway `${APP_GATEWAY_NAME}` In Resource Group `${AZ_RESOURCE_GROUP}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `app_gateway_log_errors.sh`
- **Tags**: `access:read-only`, `appgateway`, `logs`, `network`, `errors`, `data:logs-regexp`
- **Reads**: `APP_GATEWAY_NAME`, `AZ_RESOURCE_GROUP`
- **Writes**: `appgw_diagnostic_log_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### List Related Azure Resources for Application Gateway `${APP_GATEWAY_NAME}` In Resource Group `${AZ_RESOURCE_GROUP}`

Fetch a list of resources that are releated to the application gateway

- **Robot task name**: <code>List Related Azure Resources for Application Gateway `${APP_GATEWAY_NAME}` In Resource Group `${AZ_RESOURCE_GROUP}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `app_gateway_related_resources.sh`
- **Tags**: `access:read-only`, `appgateway`, `resources`, `azure`, `related`, `data:config`
- **Reads**: —
- **Writes**: `appgw_resource_discovery.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


## Monitor

Queries the health of an Azure Application Gateway, returning 1 when it's healthy and 0 when it's unhealthy.

- **Robot file**: `sli.robot`
- **Score range**: `0.0` (failing) to `1.0` (healthy)
- **Aggregation**: arithmetic mean of the sub-checks below
- **Recommended interval**: `180s`

### Sub-checks

#### Check for Resource Health Issues Affecting Application Gateway `${APP_GATEWAY_NAME}` In Resource Group `${AZ_RESOURCE_GROUP}`

Fetch a list of issues that might affect the Application Gateway as reported from Azure.

- **Robot task name**: <code>Check for Resource Health Issues Affecting Application Gateway `${APP_GATEWAY_NAME}` In Resource Group `${AZ_RESOURCE_GROUP}`</code>
- **Sub-metric name**: `resource_health`
- **Underlying script**: `app_gateway_resource_health.sh`
- **Tags**: `appgateway`, `resource`, `health`, `service`, `azure`, `access:read-only`, `data:config`
- **Reads**: —
- **Pass condition**: `"${resource_health_output_json["properties"]["title"]}" == "Available"`


#### Check Configuration Health of Application Gateway `${APP_GATEWAY_NAME}` In Resource Group `${AZ_RESOURCE_GROUP}`

Fetch the config of the AKS cluster in azure

- **Robot task name**: <code>Check Configuration Health of Application Gateway `${APP_GATEWAY_NAME}` In Resource Group `${AZ_RESOURCE_GROUP}`</code>
- **Sub-metric name**: `configuration`
- **Underlying script**: `app_gateway_config_health.sh`
- **Tags**: `appgateway`, `config`, `access:read-only`, `data:config`
- **Reads**: —
- **Pass condition**: `len(@{issue_list["issues"]}) == 0`


#### Check Backend Pool Health for Application Gateway `${APP_GATEWAY_NAME}` In Resource Group `${AZ_RESOURCE_GROUP}`

Fetch the health of the application gateway backend pool members

- **Robot task name**: <code>Check Backend Pool Health for Application Gateway `${APP_GATEWAY_NAME}` In Resource Group `${AZ_RESOURCE_GROUP}`</code>
- **Sub-metric name**: `backend_pools`
- **Underlying script**: `app_gateway_backend_health.sh`
- **Tags**: `appservice`, `logs`, `tail`, `access:read-only`, `data:config`
- **Reads**: —
- **Pass condition**: `len(@{issue_list["issues"]}) == 0`


#### Fetch Metrics for Application Gateway `${APP_GATEWAY_NAME}` In Resource Group `${AZ_RESOURCE_GROUP}`

Fetch metrics for the application gateway

- **Robot task name**: <code>Fetch Metrics for Application Gateway `${APP_GATEWAY_NAME}` In Resource Group `${AZ_RESOURCE_GROUP}`</code>
- **Sub-metric name**: `metrics`
- **Underlying script**: `app_gateway_metrics.sh`
- **Tags**: `appgateway`, `metrics`, `analytics`, `data:config`
- **Reads**: —
- **Pass condition**: `len(@{issue_list["issues"]}) == 0`


#### Check SSL Certificate Health for Application Gateway `${APP_GATEWAY_NAME}` In Resource Group `${AZ_RESOURCE_GROUP}`

Fetch SSL certificates and validate expiry dates for Azure Application Gateway instances

- **Robot task name**: <code>Check SSL Certificate Health for Application Gateway `${APP_GATEWAY_NAME}` In Resource Group `${AZ_RESOURCE_GROUP}`</code>
- **Sub-metric name**: `ssl_certificates`
- **Underlying script**: `app_gateway_ssl_certs.sh`
- **Tags**: `appgateway`, `ssl`, `expiry`, `data:config`
- **Reads**: —
- **Pass condition**: `len(@{issue_list["issues"]}) == 0`


#### Check Logs for Errors with Application Gateway `${APP_GATEWAY_NAME}` In Resource Group `${AZ_RESOURCE_GROUP}`

Query log analytics workspace for common errors like IP mismatches or subnet issues

- **Robot task name**: <code>Check Logs for Errors with Application Gateway `${APP_GATEWAY_NAME}` In Resource Group `${AZ_RESOURCE_GROUP}`</code>
- **Sub-metric name**: `error_logs`
- **Underlying script**: `app_gateway_log_errors.sh`
- **Tags**: `appgateway`, `logs`, `network`, `errors`, `data:logs-regexp`
- **Reads**: —
- **Pass condition**: `len(@{issue_list["issues"]}) == 0`


## Inputs

| Name | Type | Description | Default | Required |
|---|---|---|---|---|
| `AZ_RESOURCE_GROUP` | string | The resource group to perform actions against. | — | yes |
| `APP_GATEWAY_NAME` | string | The Azure Application Gateway to health check. | — | yes |
| `AZURE_RESOURCE_SUBSCRIPTION_ID` | string | The Azure Subscription ID for the resource. | `""` | no |
| `AZURE_SUBSCRIPTION_NAME` | string | The friendly name of the subscription ID. | `subscription-01` | no |

## Secrets

_No secrets imported in Robot source._

## Outputs

- Monitor health score (`0.0`–`1.0`) pushed by `sli.robot`
- `app_gateway_health.json`
- `app_gateway_config_health.json`
- `backend_pool_members_health.json`
- `app_gateway_log_metrics.json`
- `app_gateway_metrics.json`
- `appgw_ssl_certificate_checks.json`
- `appgw_diagnostic_log_issues.json`
- `appgw_resource_discovery.json`

## How to invoke

### Preferred: Robot Framework runner (`ro`)

```bash
cd codebundles/azure-appgateway-health
export AZ_RESOURCE_GROUP=...
export APP_GATEWAY_NAME=...
export AZURE_RESOURCE_SUBSCRIPTION_ID=...
export AZURE_SUBSCRIPTION_NAME=...
ro runbook.robot
```

### Standalone scripts (no Robot)


Set the input variables above, then run the matching script:

```bash
cd codebundles/azure-appgateway-health
export AZ_RESOURCE_GROUP=...
export APP_GATEWAY_NAME=...
export AZURE_RESOURCE_SUBSCRIPTION_ID=...
export AZURE_SUBSCRIPTION_NAME=...
bash app_gateway_backend_health.sh
bash app_gateway_comprehensive_log_check.sh
bash app_gateway_config_health.sh
bash app_gateway_log_analytics.sh
bash app_gateway_log_errors.sh
bash app_gateway_metrics.sh
bash app_gateway_related_resources.sh
bash app_gateway_resource_health.sh
bash app_gateway_ssl_certs.sh
```

## Source files

- `runbook.robot` — orchestrates tools and raises issues
- `sli.robot` — monitor scoring (`sli.robot` runtime file)
- `app_gateway_backend_health.sh` — Bash helper script `app_gateway_backend_health.sh`.
- `app_gateway_comprehensive_log_check.sh` — Bash helper script `app_gateway_comprehensive_log_check.sh`.
- `app_gateway_config_health.sh` — Bash helper script `app_gateway_config_health.sh`.
- `app_gateway_log_analytics.sh` — Bash helper script `app_gateway_log_analytics.sh`.
- `app_gateway_log_errors.sh` — Bash helper script `app_gateway_log_errors.sh`.
- `app_gateway_metrics.sh` — Bash helper script `app_gateway_metrics.sh`.
- `app_gateway_related_resources.sh` — Bash helper script `app_gateway_related_resources.sh`.
- `app_gateway_resource_health.sh` — Bash helper script `app_gateway_resource_health.sh`.
- `app_gateway_ssl_certs.sh` — Bash helper script `app_gateway_ssl_certs.sh`.
