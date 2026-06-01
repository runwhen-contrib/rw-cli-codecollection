---
name: azure-aks-triage
kind: skill-template
description: Runs diagnostic checks against an AKS cluster. Use when triaging or monitoring Azure, AKS, Kubernetes workloads with skill template `azure-aks-triage`.
runtime:
  runbook: runbook.robot
  runner: ro
platforms: [Azure, AKS, Kubernetes, Service, Triage, Health]
resource_types: [aks_cluster]
access: read-only
---

# Azure AKS Triage

## Summary

This CodeBundle checks for AKS Cluster Health based on how Azure is reporting resource health, network configuration recommendations, activities that have occured, and provisioning status of resources.

See [README.md](README.md) for additional context.

## Tools

### Check for Resource Health Issues Affecting AKS Cluster `${AKS_CLUSTER}` In Resource Group `${AZ_RESOURCE_GROUP}`

Fetch a list of issues that might affect the AKS cluster

- **Robot task name**: <code>Check for Resource Health Issues Affecting AKS Cluster `${AKS_CLUSTER}` In Resource Group `${AZ_RESOURCE_GROUP}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `aks_resource_health.sh`
- **Tags**: `aks`, `config`, `access:read-only`, `data:config`
- **Reads**: `AKS_CLUSTER`, `AZ_RESOURCE_GROUP`
- **Writes**: `az_resource_health.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Check Configuration Health of AKS Cluster `${AKS_CLUSTER}` In Resource Group `${AZ_RESOURCE_GROUP}`

Fetch the config of the AKS cluster in azure

- **Robot task name**: <code>Check Configuration Health of AKS Cluster `${AKS_CLUSTER}` In Resource Group `${AZ_RESOURCE_GROUP}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `aks_cluster_health.sh`
- **Tags**: `AKS`, `config`, `access:read-only`, `data:config`
- **Reads**: `AKS_CLUSTER`, `AZ_RESOURCE_GROUP`
- **Writes**: `az_cluster_health.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Check Network Configuration of AKS Cluster `${AKS_CLUSTER}` In Resource Group `${AZ_RESOURCE_GROUP}`

Fetch the network configuration, generating resource URLs and basic recommendations

- **Robot task name**: <code>Check Network Configuration of AKS Cluster `${AKS_CLUSTER}` In Resource Group `${AZ_RESOURCE_GROUP}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `aks_network.sh`
- **Tags**: `AKS`, `config`, `network`, `route`, `firewall`, `access:read-only`, `data:config`
- **Reads**: `AKS_CLUSTER`, `AZ_RESOURCE_GROUP`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Fetch Activities for AKS Cluster `${AKS_CLUSTER}` In Resource Group `${AZ_RESOURCE_GROUP}`

Gets the activities for the AKS cluster set and checks for errors

- **Robot task name**: <code>Fetch Activities for AKS Cluster `${AKS_CLUSTER}` In Resource Group `${AZ_RESOURCE_GROUP}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `aks_activities.sh`
- **Tags**: `AKS`, `activities`, `monitor`, `events`, `errors`, `access:read-only`, `data:logs-bulk`
- **Reads**: `AKS_CLUSTER`, `AZ_RESOURCE_GROUP`
- **Writes**: `aks_activities_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Check Kubernetes Version Support for AKS Cluster `${AKS_CLUSTER}` In Resource Group `${AZ_RESOURCE_GROUP}`

Checks whether the AKS cluster is running an unsupported or soon-to-expire Kubernetes version. AKS supports each version for ~12 months. Running unsupported versions loses SLA coverage and security patches. Premium tier with LTS ($0.60/hr) extends support for up to 2 years.

- **Robot task name**: <code>Check Kubernetes Version Support for AKS Cluster `${AKS_CLUSTER}` In Resource Group `${AZ_RESOURCE_GROUP}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `aks_version_support.sh`
- **Tags**: `AKS`, `Version`, `Deprecation`, `Cost`, `LTS`, `access:read-only`, `data:config`
- **Reads**: `AKS_CLUSTER`, `AZ_RESOURCE_GROUP`
- **Writes**: `aks_version_support.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Analyze AKS Cluster Cost Optimization Opportunities for `${AKS_CLUSTER}` In Resource Group `${AZ_RESOURCE_GROUP}`

Analyzes 30-day utilization trends using Azure Monitor to identify underutilized node pools with cost savings opportunities. Provides Azure VM pricing-based estimates for potential monthly and annual savings with severity bands: Sev4 <$2k/month, Sev3 $2k-$10k/month, Sev2 >$10k/month.

- **Robot task name**: <code>Analyze AKS Cluster Cost Optimization Opportunities for `${AKS_CLUSTER}` In Resource Group `${AZ_RESOURCE_GROUP}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `aks_cost_optimization.sh`
- **Tags**: `aks`, `cost-optimization`, `underutilization`, `azure-monitor`, `pricing`, `access:read-only`, `data:config`
- **Reads**: `AKS_CLUSTER`, `AZ_RESOURCE_GROUP`, `TIMEOUT_SECONDS`
- **Writes**: `aks_cost_optimization_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


## Inputs

| Name | Type | Description | Default | Required |
|---|---|---|---|---|
| `AZ_RESOURCE_GROUP` | string | The resource group to perform actions against. | — | yes |
| `AKS_CLUSTER` | string | The Azure AKS cluster to triage. | — | yes |
| `RW_LOOKBACK_WINDOW` | string | The time period, in minutes, to look back for activites/events. | `60` | no |
| `TIMEOUT_SECONDS` | string | Timeout in seconds for tasks (default: 900). | `900` | no |
| `AZURE_RESOURCE_SUBSCRIPTION_ID` | string | The Azure Subscription ID for the resource. | `""` | no |

## Secrets

| Name | Description | Required |
|---|---|---|
| `azure_credentials` | — | yes |

## Outputs

- `az_resource_health.json`
- `az_cluster_health.json`
- `aks_activities_issues.json`
- `aks_version_support.json`
- `aks_cost_optimization_issues.json`

## How to invoke

### Preferred: Robot Framework runner (`ro`)

```bash
cd codebundles/azure-aks-triage
export AZ_RESOURCE_GROUP=...
export AKS_CLUSTER=...
export RW_LOOKBACK_WINDOW=...
export TIMEOUT_SECONDS=...
export AZURE_RESOURCE_SUBSCRIPTION_ID=...
ro runbook.robot
```

### Standalone scripts (no Robot)


Set the input variables above, then run the matching script:

```bash
cd codebundles/azure-aks-triage
export AZ_RESOURCE_GROUP=...
export AKS_CLUSTER=...
export RW_LOOKBACK_WINDOW=...
export TIMEOUT_SECONDS=...
bash aks_activities.sh
bash aks_cluster_health.sh
bash aks_cost_optimization.sh
bash aks_network.sh
bash aks_resource_health.sh
bash aks_version_support.sh
```

## Source files

- `runbook.robot` — orchestrates tools and raises issues
- `aks_activities.sh` — Bash helper script `aks_activities.sh`.
- `aks_cluster_health.sh` — Bash helper script `aks_cluster_health.sh`.
- `aks_cost_optimization.sh` — Bash helper script `aks_cost_optimization.sh`.
- `aks_network.sh` — Bash helper script `aks_network.sh`.
- `aks_resource_health.sh` — Bash helper script `aks_resource_health.sh`.
- `aks_version_support.sh` — Bash helper script `aks_version_support.sh`.
