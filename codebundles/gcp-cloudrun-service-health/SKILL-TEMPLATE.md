---
name: gcp-cloudrun-service-health
kind: skill-template
description: Identify health and availability problems in GCP Cloud Run services -- failed revisions, services not Ready or not serving traffic, and troubled or aborted rollouts. Use when triaging or monitoring GCP, Cloud Run workloads with skill template `gcp-cloudrun-service-health`.
runtime:
  runbook: runbook.robot
  monitor: sli.robot
  executor: worker
  entrypoint: /home/runwhen/robot-runtime/runrobot.sh
  base_image: rw-base-runtime
platforms: [GCP, Cloud Run]
resource_types: [gcp_cloud_run_service, gcp_cloud_run_revision]
access: read-only
---

# GCP Cloud Run Service Health

## Summary

Monitors GCP Cloud Run services for failed revisions, services that are not
Ready or not able to serve traffic, troubled or aborted rollouts, and error
logs, and captures full service/revision configuration for review.

See [README.md](README.md) for additional context.

## Tools

### List Failed Cloud Run Revisions in GCP Project `${GCP_PROJECT_ID}`

Enumerates Cloud Run revisions whose Ready condition is not True, surfacing revision name, service, generation, and the failing condition message.

- **Robot task name**: <code>List Failed Cloud Run Revisions in GCP Project `${GCP_PROJECT_ID}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `list_failed_revisions.sh`
- **Tags**: `gcloud`, `cloudrun`, `gcp`, `${GCP_PROJECT_ID}`, `access:read-only`, `data:config`
- **Reads**: `GCP_PROJECT_ID`, `RESOURCES`
- **Writes**: `failed_revisions_issues.json`, `failed_revisions_report.json`
- **Issues raised**: severity 2-3 per non-Ready revision

### Check Cloud Run Services Ready and Serving Traffic in GCP Project `${GCP_PROJECT_ID}`

Checks the top-level Ready condition for each service and verifies traffic is routed to a Ready revision.

- **Robot task name**: <code>Check Cloud Run Services Ready and Serving Traffic in GCP Project `${GCP_PROJECT_ID}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `check_services_serving.sh`
- **Tags**: `gcloud`, `cloudrun`, `gcp`, `${GCP_PROJECT_ID}`, `access:read-only`, `data:config`
- **Reads**: `GCP_PROJECT_ID`, `RESOURCES`
- **Writes**: `services_serving_issues.json`, `services_serving_report.json`
- **Issues raised**: severity 2 (not Ready) / 3 (not serving latest ready revision)

### Detect Troubled or Aborted Cloud Run Rollouts in GCP Project `${GCP_PROJECT_ID}`

Identifies rollouts in a non-Serving state during a deploy window -- latest configuration not rolled out, rollback to a prior revision, or a configuration that failed all generation attempts.

- **Robot task name**: <code>Detect Troubled or Aborted Cloud Run Rollouts in GCP Project `${GCP_PROJECT_ID}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `check_rollouts.sh`
- **Tags**: `gcloud`, `cloudrun`, `gcp`, `${GCP_PROJECT_ID}`, `access:read-only`, `data:config`
- **Reads**: `GCP_PROJECT_ID`, `RESOURCES`
- **Writes**: `rollouts_issues.json`, `rollouts_report.json`
- **Issues raised**: severity 2-3 per troubled or aborted rollout

### Get Error Logs for Unhealthy Cloud Run Services in GCP Project `${GCP_PROJECT_ID}`

Reads ERROR-level log entries (resource.type=cloud_run_revision) within a configurable lookback window.

- **Robot task name**: <code>Get Error Logs for Unhealthy Cloud Run Services in GCP Project `${GCP_PROJECT_ID}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `get_error_logs.sh`
- **Tags**: `gcloud`, `cloudrun`, `gcp`, `${GCP_PROJECT_ID}`, `logging`, `access:read-only`, `data:logs`
- **Reads**: `GCP_PROJECT_ID`, `RESOURCES`, `ERROR_LOG_LOOKBACK`
- **Writes**: `error_logs_issues.json`, `error_logs_report.json`
- **Issues raised**: severity 3 per service with error logs

### Report Cloud Run Service and Revision Configuration in GCP Project `${GCP_PROJECT_ID}`

Dumps service and revision configuration (spec, annotations, concurrency, cpu/memory limits, env, service account, scaling) into the report for LLM review.

- **Robot task name**: <code>Report Cloud Run Service and Revision Configuration in GCP Project `${GCP_PROJECT_ID}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `capture_config.sh`
- **Tags**: `gcloud`, `cloudrun`, `gcp`, `${GCP_PROJECT_ID}`, `access:read-only`, `data:config`
- **Reads**: `GCP_PROJECT_ID`, `RESOURCES`
- **Writes**: `config_issues.json`, `config_report.json`
- **Issues raised**: severity 1 (no max instances) / 2 (default service account)

## Monitor

Binary health score: **1** only if every health dimension passes, **0** if any is degraded.

- **Robot file**: `sli.robot`
- **Score range**: `0` (degraded) or `1` (healthy)
- **Aggregation**: logical AND across the sub-checks below
- **Recommended interval**: `300s`

### Sub-checks

#### Score Failed Cloud Run Revisions in GCP Project `${GCP_PROJECT_ID}`

Scores 1 if no Cloud Run revisions are in a non-Ready state.

- **Robot task name**: <code>Score Failed Cloud Run Revisions in GCP Project `${GCP_PROJECT_ID}`</code>
- **Sub-metric names**: `revision_health`, `failed_revision_count`
- **Underlying script**: `list_failed_revisions.sh`
- **Pass condition**: `failed_revision_count == 0`

#### Score Cloud Run Services Ready and Serving in GCP Project `${GCP_PROJECT_ID}`

Scores 1 if all services are Ready with traffic on their latest ready revision.

- **Robot task name**: <code>Score Cloud Run Services Ready and Serving in GCP Project `${GCP_PROJECT_ID}`</code>
- **Sub-metric names**: `serving_health`, `unhealthy_service_count`
- **Underlying script**: `check_services_serving.sh`
- **Pass condition**: `unhealthy_service_count == 0`

#### Score Cloud Run Rollout Health in GCP Project `${GCP_PROJECT_ID}`

Scores 1 if no service is in a troubled or aborted rollout.

- **Robot task name**: <code>Score Cloud Run Rollout Health in GCP Project `${GCP_PROJECT_ID}`</code>
- **Sub-metric names**: `rollout_health`, `troubled_rollout_count`
- **Underlying script**: `check_rollouts.sh`
- **Pass condition**: `troubled_rollout_count == 0`

## Inputs

| Name | Type | Description | Default | Required |
|---|---|---|---|---|
| `GCP_PROJECT_ID` | string | The GCP Project ID to scope the API to. | — | yes |
| `RESOURCES` | string | Comma-separated Cloud Run service names to check, or `All` for auto-discovery. | `All` | no |
| `ERROR_LOG_LOOKBACK` | string | Lookback window for error log queries, e.g. `14d`. | `14d` | no |

## Secrets

| Name | Description | Required |
|---|---|---|
| `gcp_credentials` | GCP service account json used to authenticate with GCP APIs. | yes |

## Outputs

- Binary monitor health score (`0` or `1`) pushed by `sli.robot`
- Sub-metrics per health dimension with raw issue counts
- `failed_revisions_issues.json`, `failed_revisions_report.json`
- `services_serving_issues.json`, `services_serving_report.json`
- `rollouts_issues.json`, `rollouts_report.json`
- `error_logs_issues.json`, `error_logs_report.json`
- `config_issues.json`, `config_report.json`

## How to invoke

### Production (RunWhen runner / worker)

The platform **runner** schedules work on a location **worker**. The worker
image (`rw-base-runtime`) executes Robot via `runrobot.sh` with
`RW_PATH_TO_ROBOT` set to the bound path under `/home/runwhen/collection/`.

- **Runbook**: `codebundles/gcp-cloudrun-service-health/runbook.robot`
- **Monitor**: `codebundles/gcp-cloudrun-service-health/sli.robot`

### Local development (devcontainer only)

`ro` is a dev-time wrapper in `codecollection-devtools` — not the enterprise runtime.

```bash
cd codebundles/gcp-cloudrun-service-health
export GCP_PROJECT_ID=...
ro runbook.robot
```

### Standalone scripts (no Robot)

Set the input variables above, then run the matching script:

```bash
cd codebundles/gcp-cloudrun-service-health
export GCP_PROJECT_ID=...
bash list_failed_revisions.sh
bash check_services_serving.sh
bash check_rollouts.sh
bash get_error_logs.sh
bash capture_config.sh
```

## Source files

- `runbook.robot` — orchestrates tools and raises issues
- `sli.robot` — binary multi-dimensional monitor scoring
- `cloudrun_common.sh` — shared service discovery and issue helpers
- `list_failed_revisions.sh` — lists revisions with a non-True Ready condition
- `check_services_serving.sh` — checks service Ready and traffic serving
- `check_rollouts.sh` — detects troubled or aborted rollouts
- `get_error_logs.sh` — fetches ERROR logs for unhealthy services
- `capture_config.sh` — dumps service/revision configuration for review
