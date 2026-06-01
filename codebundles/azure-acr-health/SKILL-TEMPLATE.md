---
name: azure-acr-health
kind: skill-template
description: Comprehensive health checks for Azure Container Registry (ACR), including network configuration, resource health,... Use when triaging or monitoring Azure, Container, Registry workloads with skill ...
runtime:
  runbook: runbook.robot
  monitor: sli.robot
  runner: ro
platforms: [Azure, Container, Registry, ACR, Health, Network, Security, Storage]
resource_types: [container_registry]
access: read-only
---

# Azure ACR Health Check

## Summary

This bundle provides comprehensive health checks for Azure Container Registries (ACR), including network configuration analysis, resource health monitoring, authentication testing, storage utilization analysis, pull/push metrics, and security assessments.

See [README.md](README.md) for additional context.

## Tools

### Check Network Configuration for ACR `${ACR_NAME}` In Resource Group `${AZ_RESOURCE_GROUP}`

Analyze network access rules, private endpoints, firewall settings, and connectivity.

- **Robot task name**: <code>Check Network Configuration for ACR `${ACR_NAME}` In Resource Group `${AZ_RESOURCE_GROUP}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `acr_network_config.sh`
- **Tags**: `access:read-only`, `ACR`, `Azure`, `Network`, `Security`, `Connectivity`, `data:config`
- **Reads**: `ACR_NAME`, `AZ_RESOURCE_GROUP`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Check DNS & TLS Reachability for Registry `${ACR_NAME}`

Verifies DNS resolution and HTTPS/TLS for ACR endpoint.

- **Robot task name**: <code>Check DNS & TLS Reachability for Registry `${ACR_NAME}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `acr_reachability.sh`
- **Tags**: `access:read-only`, `ACR`, `Azure`, `DNS`, `TLS`, `Connectivity`, `Health`, `data:config`
- **Reads**: —
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Check ACR Login & Authentication for Registry `${ACR_NAME}`

Attempts az acr login and docker login using intended workload identity.

- **Robot task name**: <code>Check ACR Login & Authentication for Registry `${ACR_NAME}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `acr_authentication.sh`
- **Tags**: `access:read-only`, `ACR`, `Azure`, `Login`, `Auth`, `Connectivity`, `Health`, `data:config`
- **Reads**: `ACR_NAME`, `AZ_RESOURCE_GROUP`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Check ACR SKU and Usage Metrics for Registry `${ACR_NAME}`

Analyzes ACR SKU configuration, usage limits, and provides recommendations.

- **Robot task name**: <code>Check ACR SKU and Usage Metrics for Registry `${ACR_NAME}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `acr_usage_sku.sh`
- **Tags**: `access:read-only`, `ACR`, `Azure`, `SKU`, `Usage`, `Health`, `data:config`
- **Reads**: `ACR_NAME`, `AZ_RESOURCE_GROUP`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Check ACR Storage Utilization for Registry `${ACR_NAME}`

Comprehensive analysis of ACR storage usage, repository sizes, and cleanup recommendations.

- **Robot task name**: <code>Check ACR Storage Utilization for Registry `${ACR_NAME}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `acr_storage_utilization.sh`
- **Tags**: `access:read-only`, `ACR`, `Azure`, `Storage`, `Utilization`, `Health`, `data:config`
- **Reads**: `ACR_NAME`, `AZ_RESOURCE_GROUP`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Analyze ACR Pull/Push Success Ratio for Registry `${ACR_NAME}`

Analyzes pull and push operation success rates using Azure Monitor metrics and Log Analytics.

- **Robot task name**: <code>Analyze ACR Pull/Push Success Ratio for Registry `${ACR_NAME}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `acr_pull_push_ratio.sh`
- **Tags**: `access:read-only`, `ACR`, `Azure`, `Pull`, `Push`, `Metrics`, `Health`, `data:config`
- **Reads**: `ACR_NAME`, `AZ_RESOURCE_GROUP`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Check ACR Repository Event Failures for Registry `${ACR_NAME}`

Queries Log Analytics for recent failed pushes/pulls and repo errors.

- **Robot task name**: <code>Check ACR Repository Event Failures for Registry `${ACR_NAME}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `acr_events.sh`
- **Tags**: `access:read-only`, `ACR`, `Azure`, `Events`, `Health`, `data:logs-regexp`
- **Reads**: —
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Check ACR Security Configuration and RBAC for Registry `${ACR_NAME}`

Comprehensive security analysis of ACR including RBAC assignments, admin user status,

- **Robot task name**: <code>Check ACR Security Configuration and RBAC for Registry `${ACR_NAME}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `acr_rbac_security.sh`
- **Tags**: `acr`, `security`, `rbac`, `authentication`, `network`, `data:config`
- **Reads**: `ACR_NAME`, `AZ_RESOURCE_GROUP`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


## Monitor

Calculates Azure ACR health by checking reachability, SKU, pull/push ratio, and storage utilization.

- **Robot file**: `sli.robot`
- **Score range**: `0.0` (failing) to `1.0` (healthy)
- **Aggregation**: arithmetic mean of the sub-checks below
- **Recommended interval**: `180s`

### Sub-checks

#### Check ACR Reachability for Registry `${ACR_NAME}`

Checks if the ACR endpoint is reachable.

- **Robot task name**: <code>Check ACR Reachability for Registry `${ACR_NAME}`</code>
- **Sub-metric name**: `reachability`
- **Underlying script**: `acr_reachability.sh`
- **Tags**: `ACR`, `Azure`, `Reachability`, `Health`, `data:config`
- **Reads**: —


#### Check ACR Usage SKU Metric for Registry `${ACR_NAME}`

Checks the SKU and usage limits for the ACR.

- **Robot task name**: <code>Check ACR Usage SKU Metric for Registry `${ACR_NAME}`</code>
- **Sub-metric name**: `sku_usage`
- **Underlying script**: `acr_usage_sku.sh`
- **Tags**: `ACR`, `Azure`, `SKU`, `Health`, `data:config`
- **Reads**: —


#### Check ACR Pull/Push Success Ratio for Registry `${ACR_NAME}`

Checks the success rate of image pull and push operations.

- **Robot task name**: <code>Check ACR Pull/Push Success Ratio for Registry `${ACR_NAME}`</code>
- **Sub-metric name**: `pull_push_ratio`
- **Underlying script**: `acr_pull_push_ratio.sh`
- **Tags**: `ACR`, `Azure`, `PullPush`, `Health`, `data:config`
- **Reads**: —


#### Check ACR Storage Utilization for Registry `${ACR_NAME}`

Checks the storage usage of the ACR.

- **Robot task name**: <code>Check ACR Storage Utilization for Registry `${ACR_NAME}`</code>
- **Sub-metric name**: `storage_utilization`
- **Underlying script**: `acr_storage_utilization.sh`
- **Tags**: `ACR`, `Azure`, `Storage`, `Health`, `data:config`
- **Reads**: —


#### Check ACR Network Configuration for Registry `${ACR_NAME}`

Checks network access rules, private endpoints, and connectivity.

- **Robot task name**: <code>Check ACR Network Configuration for Registry `${ACR_NAME}`</code>
- **Sub-metric name**: `network_config`
- **Underlying script**: `acr_network_config.sh`
- **Tags**: `ACR`, `Azure`, `Network`, `Health`, `data:config`
- **Reads**: —


#### Check ACR Security Configuration

Analyzes ACR security configuration including RBAC, admin user settings, network access, and authentication methods.

- **Robot task name**: <code>Check ACR Security Configuration</code>
- **Sub-metric name**: `security`
- **Underlying script**: `acr_rbac_security.sh`
- **Tags**: `ACR`, `Azure`, `Security`, `RBAC`, `SLI`, `data:config`
- **Reads**: —


## Inputs

| Name | Type | Description | Default | Required |
|---|---|---|---|---|
| `AZ_RESOURCE_GROUP` | string | The resource group containing the ACR. | — | yes |
| `ACR_NAME` | string | Azure Container Registry Name. | — | yes |
| `AZURE_SUBSCRIPTION_ID` | string | The Azure Subscription ID. | — | yes |
| `AZURE_SUBSCRIPTION_NAME` | string | The Azure Subscription Name. | — | yes |
| `USAGE_THRESHOLD` | string | Threshold for acr usage | `80` | no |
| `CRITICAL_THRESHOLD` | string | Storage usage critical threshold percentage. | `95` | no |
| `TIME_PERIOD_HOURS` | string | Time period in hours for pull/push metrics analysis. | `24` | no |
| `PULL_SUCCESS_THRESHOLD` | string | Minimum pull success ratio percentage threshold. | `95` | no |
| `PUSH_SUCCESS_THRESHOLD` | string | Minimum push success ratio percentage threshold. | `98` | no |

## Secrets

_No secrets imported in Robot source._

## Outputs

- Monitor health score (`0.0`–`1.0`) pushed by `sli.robot`
- `storage_utilization_issues.json`
- `network_config_issues.json`

## How to invoke

### Preferred: Robot Framework runner (`ro`)

```bash
cd codebundles/azure-acr-health
export AZ_RESOURCE_GROUP=...
export ACR_NAME=...
export AZURE_SUBSCRIPTION_ID=...
export AZURE_SUBSCRIPTION_NAME=...
export USAGE_THRESHOLD=...
export CRITICAL_THRESHOLD=...
ro runbook.robot
```

### Standalone scripts (no Robot)


Set the input variables above, then run the matching script:

```bash
cd codebundles/azure-acr-health
export AZ_RESOURCE_GROUP=...
export ACR_NAME=...
export AZURE_SUBSCRIPTION_ID=...
export AZURE_SUBSCRIPTION_NAME=...
bash acr_authentication.sh
bash acr_events.sh
bash acr_network_config.sh
bash acr_pull_push_ratio.sh
bash acr_rbac_security.sh
bash acr_reachability.sh
bash acr_storage_usage.sh
bash acr_storage_utilization.sh
bash acr_usage_sku.sh
```

## Source files

- `runbook.robot` — orchestrates tools and raises issues
- `sli.robot` — monitor scoring (`sli.robot` runtime file)
- `acr_authentication.sh` — Bash helper script `acr_authentication.sh`.
- `acr_events.sh` — Bash helper script `acr_events.sh`.
- `acr_network_config.sh` — Bash helper script `acr_network_config.sh`.
- `acr_pull_push_ratio.sh` — Bash helper script `acr_pull_push_ratio.sh`.
- `acr_rbac_security.sh` — Bash helper script `acr_rbac_security.sh`.
- `acr_reachability.sh` — Bash helper script `acr_reachability.sh`.
- `acr_storage_usage.sh` — Bash helper script `acr_storage_usage.sh`.
- `acr_storage_utilization.sh` — Bash helper script `acr_storage_utilization.sh`.
- `acr_usage_sku.sh` — Bash helper script `acr_usage_sku.sh`.
