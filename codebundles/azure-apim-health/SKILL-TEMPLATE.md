---
name: azure-apim-health
kind: skill-template
description: Runs diagnostic checks to check the health of APIM instances. Use when triaging or monitoring Azure, APIM, Service workloads with skill template `azure-apim-health`.
runtime:
  runbook: runbook.robot
  monitor: sli.robot
  executor: worker
  entrypoint: /home/runwhen/robot-runtime/runrobot.sh
  base_image: rw-base-runtime
platforms: [Azure, APIM, Service, Triage, Health]
resource_types: [azure_resource]
access: read-only
---

# Azure APIM Health

## Summary

as login --use-device-code export APP_SERVICE_NAME=azure-apim-health-f1.

See [README.md](README.md) for additional context.

## Tools

### Gather APIM Resource Information for APIM `${APIM_NAME}` in Resource Group `${AZ_RESOURCE_GROUP}`

Collect fundamental details about the Azure subscription, resource group,

- **Robot task name**: <code>Gather APIM Resource Information for APIM `${APIM_NAME}` in Resource Group `${AZ_RESOURCE_GROUP}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `gather_apim_resource_information.sh`
- **Tags**: `apim`, `config`, `access:read-only`, `data:config`
- **Reads**: —
- **Writes**: `apim_config_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Check for Resource Health Issues Affecting APIM `${APIM_NAME}` in Resource Group `${AZ_RESOURCE_GROUP}`

Fetch Resource Health status and evaluate any reported issues for the APIM instance.

- **Robot task name**: <code>Check for Resource Health Issues Affecting APIM `${APIM_NAME}` in Resource Group `${AZ_RESOURCE_GROUP}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `apim_resource_health.sh`
- **Tags**: `apim`, `resourcehealth`, `access:read-only`, `data:config`
- **Reads**: `APIM_NAME`, `AZ_RESOURCE_GROUP`
- **Writes**: `apim_resource_health.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Fetch Key Metrics for APIM `${APIM_NAME}` in Resource Group `${AZ_RESOURCE_GROUP}`

Gather APIM metrics from Azure Monitor. Raises issues if thresholds are violated.

- **Robot task name**: <code>Fetch Key Metrics for APIM `${APIM_NAME}` in Resource Group `${AZ_RESOURCE_GROUP}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `apim_metrics.sh`
- **Tags**: `apim`, `metrics`, `analytics`, `access:read-only`, `data:config`
- **Reads**: `APIM_NAME`
- **Writes**: `apim_metrics.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Check Logs for Errors with APIM `${APIM_NAME}` in Resource Group `${AZ_RESOURCE_GROUP}`

Run apim_diagnostic_logs.sh, parse results, raise issues if logs exceed thresholds.

- **Robot task name**: <code>Check Logs for Errors with APIM `${APIM_NAME}` in Resource Group `${AZ_RESOURCE_GROUP}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `apim_diagnostic_logs.sh`
- **Tags**: `apim`, `logs`, `diagnostics`, `access:read-only`, `data:logs-regexp`
- **Reads**: `APIM_NAME`
- **Writes**: `apim_diagnostic_log_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Check Activity Logs for APIM Management Operations `${APIM_NAME}` in Resource Group `${AZ_RESOURCE_GROUP}`

Review Azure Activity Logs for administrative operations on the APIM instance

- **Robot task name**: <code>Check Activity Logs for APIM Management Operations `${APIM_NAME}` in Resource Group `${AZ_RESOURCE_GROUP}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `apim_activity_logs.sh`
- **Tags**: `apim`, `activity-logs`, `management`, `access:read-only`, `data:logs-bulk`
- **Reads**: `APIM_NAME`
- **Writes**: `apim_activity_log_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Check Application Insights Integration for APIM `${APIM_NAME}` in Resource Group `${AZ_RESOURCE_GROUP}`

Verify Application Insights integration and analyze telemetry if configured

- **Robot task name**: <code>Check Application Insights Integration for APIM `${APIM_NAME}` in Resource Group `${AZ_RESOURCE_GROUP}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `check_apim_appinsights.sh`
- **Tags**: `apim`, `application-insights`, `telemetry`, `access:read-only`, `data:config`
- **Reads**: —
- **Writes**: `apim_appinsights_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Check Key Vault Dependencies for APIM `${APIM_NAME}` in Resource Group `${AZ_RESOURCE_GROUP}`

Verify Key Vault dependencies and access for certificates and secrets

- **Robot task name**: <code>Check Key Vault Dependencies for APIM `${APIM_NAME}` in Resource Group `${AZ_RESOURCE_GROUP}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `check_apim_keyvault.sh`
- **Tags**: `apim`, `keyvault`, `certificates`, `access:read-only`, `data:config`
- **Reads**: —
- **Writes**: `apim_keyvault_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Verify APIM Policy Configurations for `${APIM_NAME}` in Resource Group `${AZ_RESOURCE_GROUP}`

Validates APIM policies for malformed XML, authentication issues, and backend connectivity problems.

- **Robot task name**: <code>Verify APIM Policy Configurations for `${APIM_NAME}` in Resource Group `${AZ_RESOURCE_GROUP}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `verify_apim_policies.sh`
- **Tags**: `apim`, `policy`, `xml`, `authentication`, `backend`, `access:read-only`, `data:config`
- **Reads**: `APIM_NAME`
- **Writes**: `apim_policy_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Check APIM SSL Certificates for `${APIM_NAME}` in Resource Group `${AZ_RESOURCE_GROUP}`

Verify certificate validity, expiration, thumbprint, and domain matches

- **Robot task name**: <code>Check APIM SSL Certificates for `${APIM_NAME}` in Resource Group `${AZ_RESOURCE_GROUP}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `check_apim_ssl_certs.sh`
- **Tags**: `apim`, `ssl`, `certificate`, `access:read-only`, `data:config`
- **Reads**: —
- **Writes**: `apim_ssl_certificate_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Inspect Dependencies and Related Resources for APIM `${APIM_NAME}` in Resource Group `${AZ_RESOURCE_GROUP}`

Runs inspect_apim_dependencies.sh to discover & validate Key Vault, backends, DNS, etc.

- **Robot task name**: <code>Inspect Dependencies and Related Resources for APIM `${APIM_NAME}` in Resource Group `${AZ_RESOURCE_GROUP}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `inspect_apim_dependencies.sh`
- **Tags**: `apim`, `dependencies`, `external`, `keyvault`, `access:read-only`, `data:config`
- **Reads**: —
- **Writes**: `apim_dependencies.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


## Monitor

Runs diagnostic checks to check the health of APIM instances

- **Robot file**: `sli.robot`
- **Score range**: `0.0` (failing) to `1.0` (healthy)
- **Aggregation**: arithmetic mean of the sub-checks below
- **Recommended interval**: `180s`

### Sub-checks

#### Check for Resource Health Issues Affecting APIM `${APIM_NAME}` in Resource Group `${AZ_RESOURCE_GROUP}`

Fetch Resource Health status and evaluate any reported issues for the APIM instance.

- **Robot task name**: <code>Check for Resource Health Issues Affecting APIM `${APIM_NAME}` in Resource Group `${AZ_RESOURCE_GROUP}`</code>
- **Sub-metric name**: `resource_health`
- **Underlying script**: `apim_resource_health.sh`
- **Tags**: `apim`, `resourcehealth`, `access:read-only`, `data:config`
- **Reads**: —
- **Pass condition**: `"${resource_health_output_json["properties"]["title"]}" == "Available"`


#### Fetch Key Metrics for APIM `${APIM_NAME}` in Resource Group `${AZ_RESOURCE_GROUP}`

Gather APIM metrics from Azure Monitor. Raises issues if thresholds are violated.

- **Robot task name**: <code>Fetch Key Metrics for APIM `${APIM_NAME}` in Resource Group `${AZ_RESOURCE_GROUP}`</code>
- **Sub-metric name**: `metrics`
- **Underlying script**: `apim_metrics.sh`
- **Tags**: `apim`, `metrics`, `analytics`, `access:read-only`, `data:config`
- **Reads**: —
- **Pass condition**: `len(@{issues_list["issues"]}) == 0`


#### Check Logs for Errors with APIM `${APIM_NAME}` in Resource Group `${AZ_RESOURCE_GROUP}`

Run apim_diagnostic_logs.sh, parse results, raise issues if logs exceed thresholds.

- **Robot task name**: <code>Check Logs for Errors with APIM `${APIM_NAME}` in Resource Group `${AZ_RESOURCE_GROUP}`</code>
- **Sub-metric name**: `diagnostic_logs`
- **Underlying script**: `apim_diagnostic_logs.sh`
- **Tags**: `apim`, `logs`, `diagnostics`, `access:read-only`, `data:logs-regexp`
- **Reads**: —
- **Pass condition**: `len(@{issue_list["issues"]}) == 0`


#### Verify APIM Policy Configurations for `${APIM_NAME}` in Resource Group `${AZ_RESOURCE_GROUP}`

Runs a shell script to enumerate all APIM policies and check for missing tags.

- **Robot task name**: <code>Verify APIM Policy Configurations for `${APIM_NAME}` in Resource Group `${AZ_RESOURCE_GROUP}`</code>
- **Sub-metric name**: `policy_config`
- **Underlying script**: `verify_apim_policies.sh`
- **Tags**: `apim`, `policy`, `config`, `access:read-only`, `data:config`
- **Reads**: —
- **Pass condition**: `len(@{issue_list["issues"]}) == 0`


#### Check APIM SSL Certificates for `${APIM_NAME}` in Resource Group `${AZ_RESOURCE_GROUP}`

Verify certificate validity, expiration, thumbprint, and domain matches

- **Robot task name**: <code>Check APIM SSL Certificates for `${APIM_NAME}` in Resource Group `${AZ_RESOURCE_GROUP}`</code>
- **Sub-metric name**: `ssl_certificates`
- **Underlying script**: `check_apim_ssl_certs.sh`
- **Tags**: `apim`, `ssl`, `certificate`, `access:read-only`, `data:config`
- **Reads**: —
- **Pass condition**: `len(@{issue_list["issues"]}) == 0`


#### Inspect Dependencies and Related Resources for APIM `${APIM_NAME}` in Resource Group `${AZ_RESOURCE_GROUP}`

Runs inspect_apim_dependencies.sh to discover & validate Key Vault, backends, DNS, etc.

- **Robot task name**: <code>Inspect Dependencies and Related Resources for APIM `${APIM_NAME}` in Resource Group `${AZ_RESOURCE_GROUP}`</code>
- **Sub-metric name**: `dependencies`
- **Underlying script**: `inspect_apim_dependencies.sh`
- **Tags**: `apim`, `dependencies`, `external`, `keyvault`, `data:config`
- **Reads**: —
- **Pass condition**: `len(@{issue_list}) == 0`


## Inputs

| Name | Type | Description | Default | Required |
|---|---|---|---|---|
| `AZ_RESOURCE_GROUP` | string | The resource group to perform actions against. | — | yes |
| `APIM_NAME` | string | The APIM Instance Name | — | yes |
| `RW_LOOKBACK_WINDOW` | string | The time period, in minutes, to look back for activites/events. | `60` | no |
| `AZURE_RESOURCE_SUBSCRIPTION_ID` | string | The Azure Subscription ID for the resource. | `""` | no |

## Secrets

_No secrets imported in Robot source._

## Outputs

- Monitor health score (`0.0`–`1.0`) pushed by `sli.robot`
- `apim_config_issues.json`
- `apim_resource_health.json`
- `apim_metrics.json`
- `apim_diagnostic_log_issues.json`
- `apim_activity_log_issues.json`
- `apim_appinsights_issues.json`
- `apim_keyvault_issues.json`
- `apim_policy_issues.json`
- `apim_ssl_certificate_issues.json`
- `apim_dependencies.json`

## How to invoke

### Production (RunWhen runner / worker)

The platform **runner** schedules work on a location **worker**. The worker
image (`rw-base-runtime`) executes Robot via `runrobot.sh` with
`RW_PATH_TO_ROBOT` set to the bound path under `/home/runwhen/collection/`.

- **Runbook**: `codebundles/azure-apim-health/runbook.robot`
- **Monitor**: `codebundles/azure-apim-health/sli.robot`

### Local development (devcontainer only)

`ro` is a dev-time wrapper in `codecollection-devtools` — not the enterprise runtime.

```bash
cd codebundles/azure-apim-health
export AZ_RESOURCE_GROUP=...
export APIM_NAME=...
export RW_LOOKBACK_WINDOW=...
export AZURE_RESOURCE_SUBSCRIPTION_ID=...
ro runbook.robot
```

### Standalone scripts (no Robot)


Set the input variables above, then run the matching script:

```bash
cd codebundles/azure-apim-health
export AZ_RESOURCE_GROUP=...
export APIM_NAME=...
export RW_LOOKBACK_WINDOW=...
export AZURE_RESOURCE_SUBSCRIPTION_ID=...
bash apim_activity_logs.sh
bash apim_diagnostic_logs.sh
bash apim_metrics.sh
bash apim_policies.sh
bash apim_resource_health.sh
bash check_apim_appinsights.sh
bash check_apim_keyvault.sh
bash check_apim_ssl_certs.sh
bash gather_apim_resource_information.sh
bash inspect_apim_dependencies.sh
bash verify_apim_policies.sh
```

## Source files

- `runbook.robot` — orchestrates tools and raises issues
- `sli.robot` — monitor scoring (`sli.robot` runtime file)
- `apim_activity_logs.sh` — Bash helper script `apim_activity_logs.sh`.
- `apim_diagnostic_logs.sh` — Bash helper script `apim_diagnostic_logs.sh`.
- `apim_metrics.sh` — Bash helper script `apim_metrics.sh`.
- `apim_policies.sh` — Bash helper script `apim_policies.sh`.
- `apim_resource_health.sh` — Bash helper script `apim_resource_health.sh`.
- `check_apim_appinsights.sh` — Bash helper script `check_apim_appinsights.sh`.
- `check_apim_keyvault.sh` — Bash helper script `check_apim_keyvault.sh`.
- `check_apim_ssl_certs.sh` — Bash helper script `check_apim_ssl_certs.sh`.
- `gather_apim_resource_information.sh` — Bash helper script `gather_apim_resource_information.sh`.
- `inspect_apim_dependencies.sh` — Bash helper script `inspect_apim_dependencies.sh`.
- `verify_apim_policies.sh` — Bash helper script `verify_apim_policies.sh`.
