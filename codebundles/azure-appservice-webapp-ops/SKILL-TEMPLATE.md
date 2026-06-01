---
name: azure-appservice-webapp-ops
kind: skill-template
description: Operational tasks for an Azure App Services, such as restarting, scaling or re-deploying. Use when triaging or monitoring Azure, AppService, Ops workloads with skill template `azure-appservice-weba...
runtime:
  runbook: runbook.robot
  executor: worker
  entrypoint: /home/runwhen/robot-runtime/runrobot.sh
  base_image: rw-base-runtime
platforms: [Azure, AppService, Ops]
resource_types: [app_service]
access: read-only
---

# Azure App Service Operations

## Summary

- Checks whether the plan supports deployment slots (Standard or Premium tier).

See [README.md](README.md) for additional context.

## Tools

### Restart App Service `${APP_SERVICE_NAME}` in Resource Group `${AZ_RESOURCE_GROUP}`

Restarts the Azure App Service and verifies success.

- **Robot task name**: <code>Restart App Service `${APP_SERVICE_NAME}` in Resource Group `${AZ_RESOURCE_GROUP}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `appservice_restart.sh`
- **Tags**: —
- **Reads**: `APP_SERVICE_NAME`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Swap Deployment Slots for App Service `${APP_SERVICE_NAME}` in Resource Group `${AZ_RESOURCE_GROUP}`

Calls the script that checks plan tier, lists slots, auto-determines source/target if only one non-prod slot

- **Robot task name**: <code>Swap Deployment Slots for App Service `${APP_SERVICE_NAME}` in Resource Group `${AZ_RESOURCE_GROUP}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `appservice_slot_swap.sh`
- **Tags**: —
- **Reads**: —
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Scale Up App Service `${APP_SERVICE_NAME}` in Resource Group `${AZ_RESOURCE_GROUP}`

Scales up the App Service to the next plan from current SKU

- **Robot task name**: <code>Scale Up App Service `${APP_SERVICE_NAME}` in Resource Group `${AZ_RESOURCE_GROUP}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `appservice_plan_scaleup.sh`
- **Tags**: —
- **Reads**: `APP_SERVICE_NAME`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Scale Down App Service `${APP_SERVICE_NAME}` in Resource Group `${AZ_RESOURCE_GROUP}`

Decreases SKU based on a predefined map (e.g. S2->S1, S1->B3, etc.)

- **Robot task name**: <code>Scale Down App Service `${APP_SERVICE_NAME}` in Resource Group `${AZ_RESOURCE_GROUP}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `appservice_plan_scaledown.sh`
- **Tags**: —
- **Reads**: `APP_SERVICE_NAME`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Scale Out Instances for App Service `${APP_SERVICE_NAME}` in Resource Group `${AZ_RESOURCE_GROUP}` by ${SCALE_OUT_FACTOR}x

Multiplies current worker count by SCALE_OUT_FACTOR

- **Robot task name**: <code>Scale Out Instances for App Service `${APP_SERVICE_NAME}` in Resource Group `${AZ_RESOURCE_GROUP}` by ${SCALE_OUT_FACTOR}x</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `appservice_scale_out.sh`
- **Tags**: —
- **Reads**: —
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Scale In Instances for App Service `${APP_SERVICE_NAME}` in Resource Group `${AZ_RESOURCE_GROUP}` to 1/${SCALE_IN_FACTOR}

Decreases the number of instances within the current App Service Plan

- **Robot task name**: <code>Scale In Instances for App Service `${APP_SERVICE_NAME}` in Resource Group `${AZ_RESOURCE_GROUP}` to 1/${SCALE_IN_FACTOR}</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `appservice_scale_in.sh`
- **Tags**: —
- **Reads**: —
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Redeploy App Service `${APP_SERVICE_NAME}` from Latest Source in Resource Group `${AZ_RESOURCE_GROUP}`

Forces a re-deployment of the Azure App Service from the configured code or container source.

- **Robot task name**: <code>Redeploy App Service `${APP_SERVICE_NAME}` from Latest Source in Resource Group `${AZ_RESOURCE_GROUP}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `appservice_redeploy.sh`
- **Tags**: —
- **Reads**: —
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


## Inputs

| Name | Type | Description | Default | Required |
|---|---|---|---|---|
| `AZ_RESOURCE_GROUP` | string | The resource group to perform actions against. | — | yes |
| `APP_SERVICE_NAME` | string | The Azure AppService to triage. | — | yes |
| `AZURE_RESOURCE_SUBSCRIPTION_ID` | string | The Azure Subscription ID for the resource. | `""` | no |
| `RW_LOOKBACK_WINDOW` | string | The time period, in minutes, to look back for activites/events. | `10` | no |
| `SCALE_OUT_FACTOR` | string | The factor by which to increase the amount of instances within the given App Service Plan. | `2` | no |
| `SCALE_IN_FACTOR` | string | The factor by which to decrease the amount of instances within the given App Service Plan. | `2` | no |
| `SOURCE_SLOT` | string | The source slot for deployment promotion. | `""` | no |
| `TARGET_SLOT` | string | The target slot for deployment promotion. | `""` | no |

## Secrets

_No secrets imported in Robot source._

## Outputs

_See Robot run output and platform report artifacts._

## How to invoke

### Production (RunWhen runner / worker)

The platform **runner** schedules work on a location **worker**. The worker
image (`rw-base-runtime`) executes Robot via `runrobot.sh` with
`RW_PATH_TO_ROBOT` set to the bound path under `/home/runwhen/collection/`.

- **Runbook**: `codebundles/azure-appservice-webapp-ops/runbook.robot`

### Local development (devcontainer only)

`ro` is a dev-time wrapper in `codecollection-devtools` — not the enterprise runtime.

```bash
cd codebundles/azure-appservice-webapp-ops
export AZ_RESOURCE_GROUP=...
export APP_SERVICE_NAME=...
export AZURE_RESOURCE_SUBSCRIPTION_ID=...
export RW_LOOKBACK_WINDOW=...
export SCALE_OUT_FACTOR=...
export SCALE_IN_FACTOR=...
ro runbook.robot
```

### Standalone scripts (no Robot)


Set the input variables above, then run the matching script:

```bash
cd codebundles/azure-appservice-webapp-ops
export AZ_RESOURCE_GROUP=...
export APP_SERVICE_NAME=...
export AZURE_RESOURCE_SUBSCRIPTION_ID=...
export RW_LOOKBACK_WINDOW=...
bash appservice_logs.sh
bash appservice_plan_scaledown.sh
bash appservice_plan_scaleup.sh
bash appservice_redeploy.sh
bash appservice_restart.sh
bash appservice_scale_in.sh
bash appservice_scale_out.sh
bash appservice_slot_swap.sh
```

## Source files

- `runbook.robot` — orchestrates tools and raises issues
- `appservice_logs.sh` — Bash helper script `appservice_logs.sh`.
- `appservice_plan_scaledown.sh` — Bash helper script `appservice_plan_scaledown.sh`.
- `appservice_plan_scaleup.sh` — Bash helper script `appservice_plan_scaleup.sh`.
- `appservice_redeploy.sh` — Bash helper script `appservice_redeploy.sh`.
- `appservice_restart.sh` — Bash helper script `appservice_restart.sh`.
- `appservice_scale_in.sh` — Bash helper script `appservice_scale_in.sh`.
- `appservice_scale_out.sh` — Bash helper script `appservice_scale_out.sh`.
- `appservice_slot_swap.sh` — Bash helper script `appservice_slot_swap.sh`.
