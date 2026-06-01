---
name: azure-vmss-triage
kind: skill-template
description: Runs diagnostic checks against virtual machine scaled sets and generates reports from key metrics. Use when triaging or monitoring Azure, Virtual, Machine workloads with skill template `azure-vmss-...
runtime:
  runbook: runbook.robot
  monitor: sli.robot
  executor: worker
  entrypoint: /home/runwhen/robot-runtime/runrobot.sh
  base_image: rw-base-runtime
platforms: [Azure, Virtual, Machine, Scale, Set, Triage, Health]
resource_types: [azure_resource]
access: read-only
---

# Azure VM Scale Set Triage

## Summary

This codebundle runs a suite of metrics checks for a VM Scale Set in Azure.

See [README.md](README.md) for additional context.

## Tools

### Check Scale Set `${VMSCALESET}` Key Metrics In Resource Group `${AZ_RESOURCE_GROUP}`

Checks key metrics of VM Scale Set for issues.

- **Robot task name**: <code>Check Scale Set `${VMSCALESET}` Key Metrics In Resource Group `${AZ_RESOURCE_GROUP}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `vmss_metrics.sh`
- **Tags**: `Scale`, `Set`, `VM`, `Azure`, `Metrics`, `Health`, `data:config`
- **Reads**: `AZ_RESOURCE_GROUP`, `VMSCALESET`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Fetch VM Scale Set `${VMSCALESET}` Config In Resource Group `${AZ_RESOURCE_GROUP}`

Fetch the config of the scaled set in azure

- **Robot task name**: <code>Fetch VM Scale Set `${VMSCALESET}` Config In Resource Group `${AZ_RESOURCE_GROUP}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `vmss_config.sh`
- **Tags**: `VM`, `Scale`, `Set`, `logs`, `tail`, `data:config`
- **Reads**: —
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Fetch Activities for VM Scale Set `${VMSCALESET}` In Resource Group `${AZ_RESOURCE_GROUP}`

Gets the events for the scaled set and checks for errors

- **Robot task name**: <code>Fetch Activities for VM Scale Set `${VMSCALESET}` In Resource Group `${AZ_RESOURCE_GROUP}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `vmss_activities.sh`
- **Tags**: `VM`, `Scale`, `Set`, `monitor`, `events`, `errors`, `data:logs-bulk`
- **Reads**: `AZ_RESOURCE_GROUP`, `VMSCALESET`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


## Monitor

Checks VM Scale Set key metrics and returns a 1 when healthy, or 0 when not healthy.

- **Robot file**: `sli.robot`
- **Score range**: `0.0` (failing) to `1.0` (healthy)
- **Aggregation**: arithmetic mean of the sub-checks below
- **Recommended interval**: `180s`

### Sub-checks

#### Check Scale Set `${VMSCALESET}` Key Metrics In Resource Group `${AZ_RESOURCE_GROUP}`

Checks key metrics of VM Scale Set for issues.

- **Robot task name**: <code>Check Scale Set `${VMSCALESET}` Key Metrics In Resource Group `${AZ_RESOURCE_GROUP}`</code>
- **Sub-metric name**: `vmss_health`
- **Underlying script**: `vmss_metrics.sh`
- **Tags**: `Scale`, `Set`, `VM`, `Azure`, `Metrics`, `Health`, `data:config`
- **Reads**: —


## Inputs

| Name | Type | Description | Default | Required |
|---|---|---|---|---|
| `AZ_RESOURCE_GROUP` | string | The resource group to perform actions against. | — | yes |
| `VMSCALESET` | string | The Azure Virtual Machine Scale Set to triage. | — | yes |
| `RW_LOOKBACK_WINDOW` | string | The time period, in minutes, to look back for activites/events. | `60` | no |
| `AZURE_RESOURCE_SUBSCRIPTION_ID` | string | The Azure Subscription ID for the resource. | `""` | no |

## Secrets

_No secrets imported in Robot source._

## Outputs

- Monitor health score (`0.0`–`1.0`) pushed by `sli.robot`

## How to invoke

### Production (RunWhen runner / worker)

The platform **runner** schedules work on a location **worker**. The worker
image (`rw-base-runtime`) executes Robot via `runrobot.sh` with
`RW_PATH_TO_ROBOT` set to the bound path under `/home/runwhen/collection/`.

- **Runbook**: `codebundles/azure-vmss-triage/runbook.robot`
- **Monitor**: `codebundles/azure-vmss-triage/sli.robot`

### Local development (devcontainer only)

`ro` is a dev-time wrapper in `codecollection-devtools` — not the enterprise runtime.

```bash
cd codebundles/azure-vmss-triage
export AZ_RESOURCE_GROUP=...
export VMSCALESET=...
export RW_LOOKBACK_WINDOW=...
export AZURE_RESOURCE_SUBSCRIPTION_ID=...
ro runbook.robot
```

### Standalone scripts (no Robot)


Set the input variables above, then run the matching script:

```bash
cd codebundles/azure-vmss-triage
export AZ_RESOURCE_GROUP=...
export VMSCALESET=...
export RW_LOOKBACK_WINDOW=...
export AZURE_RESOURCE_SUBSCRIPTION_ID=...
bash vmss_activities.sh
bash vmss_config.sh
bash vmss_metrics.sh
```

## Source files

- `runbook.robot` — orchestrates tools and raises issues
- `sli.robot` — monitor scoring (`sli.robot` runtime file)
- `vmss_activities.sh` — Bash helper script `vmss_activities.sh`.
- `vmss_config.sh` — Bash helper script `vmss_config.sh`.
- `vmss_metrics.sh` — Bash helper script `vmss_metrics.sh`.
