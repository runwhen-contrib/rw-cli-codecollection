---
name: azure-kv-health
description: Check Azure Key Vault health by checking availability metrics, configuration settings, expiring items... Use when triaging or monitoring Azure, Key, Vault workloads with skill template `azure-kv-he...
runtime:
  runbook: runbook.robot
  monitor: sli.robot
  runner: ro
platforms: [Azure, Key, Vault, Health]
resource_types: [key_vault]
access: read-only
---

# Azure Key Vault Health

## Summary

This codebundle runs a suite of metrics checks for Key Vault in Azure.

See [README.md](README.md) for additional context.

## Tools

### Check Key Vault Resource Health in resource group `${AZURE_RESOURCE_GROUP}`

Check the health status of Key Vaults in the specified resource group

- **Robot task name**: <code>Check Key Vault Resource Health in resource group `${AZURE_RESOURCE_GROUP}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `kv_resource_health.sh`
- **Tags**: `KeyVault`, `Azure`, `Health`, `access:read-only`, `data:config`
- **Reads**: `AZURE_RESOURCE_GROUP`
- **Writes**: `keyvault_health.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Check Key Vault Availability in resource group `${AZURE_RESOURCE_GROUP}`

List number of Azure key vault vaults with availability below 100%

- **Robot task name**: <code>Check Key Vault Availability in resource group `${AZURE_RESOURCE_GROUP}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `availability.sh`
- **Tags**: `KeyVault`, `Azure`, `Health`, `Monitoring`, `access:read-only`, `data:config`
- **Reads**: `AZURE_RESOURCE_GROUP`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Check Key Vault Configuration in resource group `${AZURE_RESOURCE_GROUP}`

List Key Vault miss-configuration

- **Robot task name**: <code>Check Key Vault Configuration in resource group `${AZURE_RESOURCE_GROUP}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `kv_config.sh`
- **Tags**: `KeyVault`, `Azure`, `Configuration`, `access:read-only`, `data:config`
- **Reads**: `AZURE_RESOURCE_GROUP`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Check Expiring Key Vault Items in resource group `${AZURE_RESOURCE_GROUP}`

Check for expiring secrets, certificates, and keys in Key Vaults

- **Robot task name**: <code>Check Expiring Key Vault Items in resource group `${AZURE_RESOURCE_GROUP}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `expiry-checks.sh`
- **Tags**: `KeyVault`, `Azure`, `Expiry`, `access:read-only`, `data:config`
- **Reads**: `AZURE_RESOURCE_GROUP`
- **Writes**: `kv_expiry_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Check Key Vault Logs for Issues in resource group `${AZURE_RESOURCE_GROUP}`

Check Key Vault log issues

- **Robot task name**: <code>Check Key Vault Logs for Issues in resource group `${AZURE_RESOURCE_GROUP}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `log.sh`
- **Tags**: `KeyVault`, `Azure`, `Logs`, `access:read-only`, `data:logs-regexp`
- **Reads**: `AZURE_RESOURCE_GROUP`
- **Writes**: `kv_log_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Check Key Vault Performance Metrics in resource group `${AZURE_RESOURCE_GROUP}`

Check Key Vault performance metrics for excessive requests and high latency

- **Robot task name**: <code>Check Key Vault Performance Metrics in resource group `${AZURE_RESOURCE_GROUP}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `performance_metrics.sh`
- **Tags**: `KeyVault`, `Azure`, `Metrics`, `access:read-only`, `data:config`
- **Reads**: `AZURE_RESOURCE_GROUP`
- **Writes**: `azure_keyvault_performance_metrics.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


## Monitor

Counts Azure Key Vault health by checking availability metrics, configuration settings, expiring items (secrets/certificates/keys), log issues, and performance metrics

- **Robot file**: `sli.robot`
- **Score range**: `0.0` (failing) to `1.0` (healthy)
- **Aggregation**: arithmetic mean of the sub-checks below
- **Recommended interval**: `180s`

### Sub-checks

#### Count Key Vault Resource Health in resource group `${AZURE_RESOURCE_GROUP}`

Counts the health status of Key Vaults in the specified resource group

- **Robot task name**: <code>Count Key Vault Resource Health in resource group `${AZURE_RESOURCE_GROUP}`</code>
- **Sub-metric name**: `resource_health`
- **Underlying script**: `kv_resource_health.sh`
- **Tags**: `KeyVault`, `Azure`, `Health`, `access:read-only`, `data:config`
- **Reads**: —
- **Pass condition**: `${issue_count} == 0`


#### Count Key Vault Availability in resource group `${AZURE_RESOURCE_GROUP}`

Counts number of Azure key vault vaults with availability below 100%

- **Robot task name**: <code>Count Key Vault Availability in resource group `${AZURE_RESOURCE_GROUP}`</code>
- **Sub-metric name**: `availability`
- **Underlying script**: `availability.sh`
- **Tags**: `KeyVault`, `Azure`, `Health`, `Monitoring`, `access:read-only`, `data:config`
- **Reads**: —
- **Pass condition**: `${issue_count} == 0`


#### Count Key Vault configuration in resource group `${AZURE_RESOURCE_GROUP}`

Count Key vault's miss-configuration

- **Robot task name**: <code>Count Key Vault configuration in resource group `${AZURE_RESOURCE_GROUP}`</code>
- **Sub-metric name**: `configuration`
- **Underlying script**: `kv_config.sh`
- **Tags**: `KeyVault`, `Azure`, `Configuration`, `access:read-only`, `data:config`
- **Reads**: —
- **Pass condition**: `${issue_count} == 0`


#### Count Expiring Key Vault Items in resource group `${AZURE_RESOURCE_GROUP}`

Count expiring secrets, certificates, and keys in Key Vaults

- **Robot task name**: <code>Count Expiring Key Vault Items in resource group `${AZURE_RESOURCE_GROUP}`</code>
- **Sub-metric name**: `expiring_items`
- **Underlying script**: `expiry-checks.sh`
- **Tags**: `KeyVault`, `Azure`, `Expiry`, `access:read-only`, `data:config`
- **Reads**: —
- **Pass condition**: `${issue_count} == 0`


#### Count Key Vault Log Issues in resource group `${AZURE_RESOURCE_GROUP}`

Count Key Vault log issues

- **Robot task name**: <code>Count Key Vault Log Issues in resource group `${AZURE_RESOURCE_GROUP}`</code>
- **Sub-metric name**: `log_issues`
- **Underlying script**: `log.sh`
- **Tags**: `KeyVault`, `Azure`, `Logs`, `access:read-only`, `data:logs-regexp`
- **Reads**: —
- **Pass condition**: `${issue_count} == 0`


#### Count Key Vault Performance Metrics in resource group `${AZURE_RESOURCE_GROUP}`

Count Key Vault performance metrics issues

- **Robot task name**: <code>Count Key Vault Performance Metrics in resource group `${AZURE_RESOURCE_GROUP}`</code>
- **Sub-metric name**: `performance_metrics`
- **Underlying script**: `performance_metrics.sh`
- **Tags**: `KeyVault`, `Azure`, `Metrics`, `access:read-only`, `data:config`
- **Reads**: —
- **Pass condition**: `${issue_count} == 0`


## Inputs

| Name | Type | Description | Default | Required |
|---|---|---|---|---|
| `AZURE_RESOURCE_SUBSCRIPTION_ID` | string | The Azure Subscription ID for the resource. | `""` | no |
| `AZURE_RESOURCE_GROUP` | string | Azure resource group. | — | yes |
| `THRESHOLD_DAYS` | integer | Number of days before expiration to trigger alerts | `31` | no |
| `REQUEST_THRESHOLD` | integer | Threshold for excessive requests (requests/hour) | `1000` | no |
| `LATENCY_THRESHOLD` | integer | Threshold for high latency (milliseconds) | `500` | no |
| `REQUEST_INTERVAL` | string | Interval for request count metrics (format: PT1H, PT30M, PT5M, etc.) | `PT1H` | no |
| `LATENCY_INTERVAL` | string | Interval for latency metrics (format: PT1H, PT30M, PT5M, etc.) | `PT1H` | no |
| `TIME_RANGE` | integer | Time range in hours to look back for metrics | `24` | no |
| `LOG_QUERY_DAYS` | string | Time range for log queries (format: 1d, 7d, 30d, etc.) | `1d` | no |
| `SEVERITY_REQUEST` | string | Severity level for excessive request issues (1=Low, 2=Medium, 3=High, 4=Critical) | `3` | no |
| `SEVERITY_LATENCY` | string | Severity level for high latency issues (1=Low, 2=Medium, 3=High, 4=Critical) | `3` | no |

## Secrets

_No secrets imported in Robot source._

## Outputs

- Monitor health score (`0.0`–`1.0`) pushed by `sli.robot`
- `keyvault_health.json`
- `kv_expiry_issues.json`
- `kv_log_issues.json`
- `azure_keyvault_performance_metrics.json`

## How to invoke

### Preferred: Robot Framework runner (`ro`)

```bash
cd codebundles/azure-kv-health
export AZURE_RESOURCE_SUBSCRIPTION_ID=...
export AZURE_RESOURCE_GROUP=...
export THRESHOLD_DAYS=...
export REQUEST_THRESHOLD=...
export LATENCY_THRESHOLD=...
export REQUEST_INTERVAL=...
ro runbook.robot
```

### Standalone scripts (no Robot)


Set the input variables above, then run the matching script:

```bash
cd codebundles/azure-kv-health
export AZURE_RESOURCE_SUBSCRIPTION_ID=...
export AZURE_RESOURCE_GROUP=...
export THRESHOLD_DAYS=...
export REQUEST_THRESHOLD=...
bash availability.sh
bash expiry-checks.sh
bash kv_config.sh
bash kv_resource_health.sh
bash log.sh
bash performance_metrics.sh
```

## Source files

- `runbook.robot` — orchestrates tools and raises issues
- `sli.robot` — monitor scoring (`sli.robot` runtime file)
- `availability.sh` — Bash helper script `availability.sh`.
- `expiry-checks.sh` — Bash helper script `expiry-checks.sh`.
- `kv_config.sh` — Bash helper script `kv_config.sh`.
- `kv_resource_health.sh` — Bash helper script `kv_resource_health.sh`.
- `log.sh` — Bash helper script `log.sh`.
- `performance_metrics.sh` — Bash helper script `performance_metrics.sh`.
