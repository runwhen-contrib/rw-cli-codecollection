---
name: gcloud-log-inspection
kind: skill-template
description: Fetches logs from a GCP using a configurable query and raises an issue with details on the most common issues. Use when triaging or monitoring GCP, Gcloud, Google Monitoring workloads with skill te...
runtime:
  runbook: runbook.robot
  executor: worker
  entrypoint: /home/runwhen/robot-runtime/runrobot.sh
  base_image: rw-base-runtime
platforms: [GCP, Gcloud, Google Monitoring]
resource_types: [gcp_resource]
access: read-only
---

# GCP Gcloud Log Inspection

## Summary

Runs a task which performs an inspection on your logs in a GCP project, returning results regarding common issues, counts and related Kubernetes namespaces using a filter.

See [README.md](README.md) for additional context.

## Tools

### Inspect GCP Logs For Common Errors in GCP Project `${GCP_PROJECT_ID}`

Fetches logs from a Google Cloud Project and filters for a count of common error messages.

- **Robot task name**: <code>Inspect GCP Logs For Common Errors in GCP Project `${GCP_PROJECT_ID}`</code>
- **Robot file**: `runbook.robot`
- **Tags**: `Logs`, `Query`, `Gcloud`, `GCP`, `Errors`, `Common`, `access:read-only`, `data:logs-regexp`
- **Reads**: `ADD_FILTERS`, `GCP_PROJECT_ID`, `SEVERITY`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


## Inputs

| Name | Type | Description | Default | Required |
|---|---|---|---|---|
| `SEVERITY` | string | What minimum severity to filter for. See https://cloud.google.com/logging/docs/reference/v2/rest/v2/LogEntry#LogSeverity for examples. | `ERROR` | no |
| `ADD_FILTERS` | string | Extra optional filters to add to the gcloud log read request. See https://cloud.google.com/logging/docs/view/logging-query-language for syntax. | `` | yes |
| `GCP_PROJECT_ID` | string | The GCP Project ID to scope the API to. | — | yes |

## Secrets

| Name | Description | Required |
|---|---|---|
| `gcp_credentials` | GCP service account json used to authenticate with GCP APIs. | yes |

## Outputs

_See Robot run output and platform report artifacts._

## How to invoke

### Production (RunWhen runner / worker)

The platform **runner** schedules work on a location **worker**. The worker
image (`rw-base-runtime`) executes Robot via `runrobot.sh` with
`RW_PATH_TO_ROBOT` set to the bound path under `/home/runwhen/collection/`.

- **Runbook**: `codebundles/gcloud-log-inspection/runbook.robot`

### Local development (devcontainer only)

`ro` is a dev-time wrapper in `codecollection-devtools` — not the enterprise runtime.

```bash
cd codebundles/gcloud-log-inspection
export SEVERITY=...
export ADD_FILTERS=...
export GCP_PROJECT_ID=...
ro runbook.robot
```

### Standalone scripts (no Robot)


_No standalone shell scripts in this bundle._

## Source files

- `runbook.robot` — orchestrates tools and raises issues
