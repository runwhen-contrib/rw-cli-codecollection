---
name: azure-acr-image-sync
kind: skill-template
description: This CodeBundle syncs images from public repostitories into an Azure Container Registry. Use when triaging or monitoring Azure, ACR workloads with skill template `azure-acr-image-sync`.
runtime:
  runbook: runbook.robot
  monitor: sli.robot
  executor: worker
  entrypoint: /home/runwhen/robot-runtime/runrobot.sh
  base_image: rw-base-runtime
platforms: [Azure, ACR]
resource_types: [container_registry]
access: read-only
---

# Azure ACR Image Sync

## Summary

**Purpose**: This CodeBundle synchronizes container images from public repositories into an Azure Container Registry (ACR).

See [README.md](README.md) for additional context.

## Tools

### Sync Container Images into Azure Container Registry `${ACR_REGISTRY}`

Synchronizes the latest container images into an ACR repository

- **Robot task name**: <code>Sync Container Images into Azure Container Registry `${ACR_REGISTRY}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `acr_sync_images.sh`
- **Tags**: `azure`, `acr`, `registry`, `runwhen`, `data:config`
- **Reads**: `DOCKER_TOKEN`, `DOCKER_USERNAME`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


## Monitor

This CodeBundle counts the number of container images (from a configured list) outdated. It compares upstream images with those in the registry and counts the number that are outdated.

- **Robot file**: `sli.robot`
- **Score range**: `0.0` (failing) to `1.0` (healthy)
- **Aggregation**: arithmetic mean of the sub-checks below
- **Recommended interval**: `180s`

### Sub-checks

#### Count Outdated Images in Azure Container Registry `${ACR_REGISTRY}`

Counts the number of images that need updating in ACR from the upstream source.

- **Robot task name**: <code>Count Outdated Images in Azure Container Registry `${ACR_REGISTRY}`</code>
- **Sub-metric name**: `outdated_images`
- **Underlying script**: `check_for_image_updates.sh`
- **Tags**: `azure`, `acr`, `registry`, `runwhen`, `data:config`
- **Reads**: `DOCKER_TOKEN`, `DOCKER_USERNAME`


## Inputs

| Name | Type | Description | Default | Required |
|---|---|---|---|---|
| `ACR_REGISTRY` | string | The name of the Azure Container Registry to import images into. | `myacr.azurecr.io` | no |
| `USE_DATE_TAG_PATTERN` | string | Change the image tag to use the current date and time. Useful when importing 'latest' tags | `false` | no |
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

- **Runbook**: `codebundles/azure-acr-image-sync/runbook.robot`
- **Monitor**: `codebundles/azure-acr-image-sync/sli.robot`

### Local development (devcontainer only)

`ro` is a dev-time wrapper in `codecollection-devtools` — not the enterprise runtime.

```bash
cd codebundles/azure-acr-image-sync
export ACR_REGISTRY=...
export USE_DATE_TAG_PATTERN=...
export AZURE_RESOURCE_SUBSCRIPTION_ID=...
ro runbook.robot
```

### Standalone scripts (no Robot)


Set the input variables above, then run the matching script:

```bash
cd codebundles/azure-acr-image-sync
export ACR_REGISTRY=...
export USE_DATE_TAG_PATTERN=...
export AZURE_RESOURCE_SUBSCRIPTION_ID=...
bash acr_sync_images.sh
bash check_for_image_updates.sh
```

## Source files

- `runbook.robot` — orchestrates tools and raises issues
- `sli.robot` — monitor scoring (`sli.robot` runtime file)
- `acr_sync_images.sh` — Bash helper script `acr_sync_images.sh`.
- `check_for_image_updates.sh` — Bash helper script `check_for_image_updates.sh`.
