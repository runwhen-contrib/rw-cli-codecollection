---
name: gcp-cloud-function-health
kind: skill-template
description: Identify problems related to GCP Cloud Function deployments. Use when triaging or monitoring GCP, Cloud Functions workloads with skill template `gcp-cloud-function-health`.
runtime:
  runbook: runbook.robot
  monitor: sli.robot
  executor: worker
  entrypoint: /home/runwhen/robot-runtime/runrobot.sh
  base_image: rw-base-runtime
platforms: [GCP, Cloud Functions]
resource_types: [gcp_resource]
access: read-only
---

# GCP Cloud Function Health

## Summary

This code checks if any GCP (Google Cloud Platform) cloud functions are unhealthy.

See [README.md](README.md) for additional context.

## Tools

### List Unhealthy Cloud Functions in GCP Project `${GCP_PROJECT_ID}`

Fetches a list of GCP Cloud Functions that are not healthy.

- **Robot task name**: <code>List Unhealthy Cloud Functions in GCP Project `${GCP_PROJECT_ID}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `cloud_functions_next_steps.sh`
- **Tags**: `gcloud`, `function`, `gcp`, `${GCP_PROJECT_ID}`, `access:read-only`, `data:config`
- **Reads**: `GCP_PROJECT_ID`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Get Error Logs for Unhealthy Cloud Functions in GCP Project `${GCP_PROJECT_ID}`

Fetches GCP logs related to unhealthy Cloud Functions within the last 14 days

- **Robot task name**: <code>Get Error Logs for Unhealthy Cloud Functions in GCP Project `${GCP_PROJECT_ID}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `cloud_functions_next_steps.sh`
- **Tags**: `gcloud`, `function`, `gcp`, `${GCP_PROJECT_ID}`, `access:read-only`, `data:logs-regexp`
- **Reads**: `GCP_PROJECT_ID`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


## Monitor

Count the number of Cloud Functions in an unhealthy state for a GCP Project.

- **Robot file**: `sli.robot`
- **Score range**: `0.0` (failing) to `1.0` (healthy)
- **Aggregation**: arithmetic mean of the sub-checks below
- **Recommended interval**: `180s`

### Sub-checks

#### Count unhealthy GCP Cloud Functions in GCP Project `${GCP_PROJECT_ID}`

Counts all GCP Functions that are not in a Healthy state

- **Robot task name**: <code>Count unhealthy GCP Cloud Functions in GCP Project `${GCP_PROJECT_ID}`</code>
- **Sub-metric name**: `function_health`
- **Tags**: `gcloud`, `function`, `gcp`, `${GCP_PROJECT_ID}`, `data:config`
- **Reads**: `GCP_PROJECT_ID`


## Inputs

| Name | Type | Description | Default | Required |
|---|---|---|---|---|
| `GCP_PROJECT_ID` | string | The GCP Project ID to scope the API to. | — | yes |

## Secrets

| Name | Description | Required |
|---|---|---|
| `gcp_credentials` | GCP service account json used to authenticate with GCP APIs. | yes |

## Outputs

- Monitor health score (`0.0`–`1.0`) pushed by `sli.robot`

## How to invoke

### Production (RunWhen runner / worker)

The platform **runner** schedules work on a location **worker**. The worker
image (`rw-base-runtime`) executes Robot via `runrobot.sh` with
`RW_PATH_TO_ROBOT` set to the bound path under `/home/runwhen/collection/`.

- **Runbook**: `codebundles/gcp-cloud-function-health/runbook.robot`
- **Monitor**: `codebundles/gcp-cloud-function-health/sli.robot`

### Local development (devcontainer only)

`ro` is a dev-time wrapper in `codecollection-devtools` — not the enterprise runtime.

```bash
cd codebundles/gcp-cloud-function-health
export GCP_PROJECT_ID=...
ro runbook.robot
```

### Standalone scripts (no Robot)


Set the input variables above, then run the matching script:

```bash
cd codebundles/gcp-cloud-function-health
export GCP_PROJECT_ID=...
bash cloud_functions_next_steps.sh
```

## Source files

- `runbook.robot` — orchestrates tools and raises issues
- `sli.robot` — monitor scoring (`sli.robot` runtime file)
- `cloud_functions_next_steps.sh` — Bash helper script `cloud_functions_next_steps.sh`.
