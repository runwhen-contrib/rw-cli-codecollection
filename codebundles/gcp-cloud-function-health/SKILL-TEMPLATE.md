---
name: gcp-cloud-function-health
kind: skill-template
description: Identify health, security, and configuration problems in GCP Cloud Functions (gen1 and gen2). Use when triaging or monitoring GCP, Cloud Functions workloads with skill template `gcp-cloud-function-health`.
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

Monitors GCP Cloud Functions (gen1 and gen2) for unhealthy deployments,
error logs, insecure IAM policies, gen2 Cloud Run service failures,
failed builds, and scaling/timeout misconfigurations.

See [README.md](README.md) for additional context.

## Tools

### List Unhealthy Cloud Functions in GCP Project `${GCP_PROJECT_ID}`

Fetches Cloud Functions (gen1 and gen2) whose state/status is not ACTIVE, with per-generation state message details.

- **Robot task name**: <code>List Unhealthy Cloud Functions in GCP Project `${GCP_PROJECT_ID}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `cloud_functions_next_steps.sh`
- **Tags**: `gcloud`, `function`, `gcp`, `${GCP_PROJECT_ID}`, `access:read-only`, `data:config`
- **Reads**: `GCP_PROJECT_ID`
- **Writes**: —
- **Issues raised**: severity 1 per unhealthy function

### Get Error Logs for Unhealthy Cloud Functions in GCP Project `${GCP_PROJECT_ID}`

Fetches ERROR logs from the last 14 days for unhealthy functions. Gen1 logs under `resource.type=cloud_function`; gen2 under `resource.type=cloud_run_revision`.

- **Robot task name**: <code>Get Error Logs for Unhealthy Cloud Functions in GCP Project `${GCP_PROJECT_ID}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `cloud_functions_next_steps.sh`
- **Tags**: `gcloud`, `function`, `gcp`, `${GCP_PROJECT_ID}`, `access:read-only`, `data:logs-regexp`
- **Reads**: `GCP_PROJECT_ID`
- **Writes**: —
- **Issues raised**: severity 3 per function with error logs

### Fetch Cloud Function Configurations in GCP Project `${GCP_PROJECT_ID}`

Fetches full configuration (runtime, memory, timeout, ingress, VPC, service account) for every function; flags functions using the default compute service account.

- **Robot task name**: <code>Fetch Cloud Function Configurations in GCP Project `${GCP_PROJECT_ID}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `fetch_function_config.sh`
- **Tags**: `gcloud`, `function`, `gcp`, `${GCP_PROJECT_ID}`, `access:read-only`, `data:config`
- **Reads**: `GCP_PROJECT_ID`
- **Writes**: `function_config_report.json`, `function_config_issues.json`
- **Issues raised**: severity 3 per function without a dedicated service account

### Check Cloud Function IAM Policies in GCP Project `${GCP_PROJECT_ID}`

Flags functions granting invoker access to `allUsers` or `allAuthenticatedUsers` (publicly invocable).

- **Robot task name**: <code>Check Cloud Function IAM Policies in GCP Project `${GCP_PROJECT_ID}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `check_function_iam.sh`
- **Tags**: `gcloud`, `function`, `gcp`, `${GCP_PROJECT_ID}`, `security`, `access:read-only`, `data:config`
- **Reads**: `GCP_PROJECT_ID`
- **Writes**: `function_iam_issues.json`
- **Issues raised**: severity 2 per publicly invocable function

### Check Gen2 Cloud Run Service Health in GCP Project `${GCP_PROJECT_ID}`

Checks the Cloud Run services backing gen2 functions: Ready conditions, revision health, and traffic routing.

- **Robot task name**: <code>Check Gen2 Cloud Run Service Health in GCP Project `${GCP_PROJECT_ID}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `check_gen2_run_health.sh`
- **Tags**: `gcloud`, `function`, `cloudrun`, `gcp`, `${GCP_PROJECT_ID}`, `access:read-only`, `data:config`
- **Reads**: `GCP_PROJECT_ID`
- **Writes**: `gen2_run_health_report.json`, `gen2_run_health_issues.json`
- **Issues raised**: severity 2 (service not Ready) / severity 3 (no traffic on latest revision)

### Check for Failed Cloud Function Builds in GCP Project `${GCP_PROJECT_ID}`

Detects failed function deployments (state messages) and failed Cloud Build jobs (gen2 builds).

- **Robot task name**: <code>Check for Failed Cloud Function Builds in GCP Project `${GCP_PROJECT_ID}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `check_function_builds.sh`
- **Tags**: `gcloud`, `function`, `cloudbuild`, `gcp`, `${GCP_PROJECT_ID}`, `access:read-only`, `data:config`
- **Reads**: `GCP_PROJECT_ID`
- **Writes**: `function_build_issues.json`
- **Issues raised**: severity 2 (failed deployment) / severity 3 (failed build job)

### Check Cloud Function Scaling and Timeout Configuration in GCP Project `${GCP_PROJECT_ID}`

Flags HTTP functions with long timeouts and gen2 functions without a max instance cap (unbounded scaling cost risk).

- **Robot task name**: <code>Check Cloud Function Scaling and Timeout Configuration in GCP Project `${GCP_PROJECT_ID}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `check_function_scaling.sh`
- **Tags**: `gcloud`, `function`, `gcp`, `${GCP_PROJECT_ID}`, `access:read-only`, `data:config`
- **Reads**: `GCP_PROJECT_ID`
- **Writes**: `function_scaling_issues.json`
- **Issues raised**: severity 4 (long HTTP timeout / unbounded scaling)

## Monitor

Binary health score: **1** only if every health dimension passes, **0** if any is degraded.

- **Robot file**: `sli.robot`
- **Score range**: `0` (degraded) or `1` (healthy)
- **Aggregation**: logical AND across the sub-checks below
- **Recommended interval**: `300s`

### Sub-checks

#### Score Unhealthy Cloud Functions in GCP Project `${GCP_PROJECT_ID}`

Scores 1 if no Cloud Functions (gen1 or gen2) are in a non-ACTIVE state.

- **Robot task name**: <code>Score Unhealthy Cloud Functions in GCP Project `${GCP_PROJECT_ID}`</code>
- **Sub-metric names**: `function_state`, `unhealthy_function_count`
- **Tags**: `gcloud`, `function`, `gcp`, `${GCP_PROJECT_ID}`, `data:config`
- **Pass condition**: `unhealthy_function_count == 0`

#### Score Cloud Function IAM Configuration in GCP Project `${GCP_PROJECT_ID}`

Scores 1 if no function grants invoker access to `allUsers`/`allAuthenticatedUsers`.

- **Robot task name**: <code>Score Cloud Function IAM Configuration in GCP Project `${GCP_PROJECT_ID}`</code>
- **Sub-metric names**: `iam_config`, `public_invoker_count`
- **Underlying script**: `check_function_iam.sh`
- **Tags**: `gcloud`, `function`, `gcp`, `${GCP_PROJECT_ID}`, `security`, `data:config`
- **Pass condition**: `function_iam_issues.json length == 0`

#### Score Cloud Function Build Health in GCP Project `${GCP_PROJECT_ID}`

Scores 1 if no failed deployments or failed Cloud Build jobs exist.

- **Robot task name**: <code>Score Cloud Function Build Health in GCP Project `${GCP_PROJECT_ID}`</code>
- **Sub-metric names**: `build_health`, `failed_build_count`
- **Underlying script**: `check_function_builds.sh`
- **Tags**: `gcloud`, `function`, `cloudbuild`, `gcp`, `${GCP_PROJECT_ID}`, `data:config`
- **Pass condition**: `function_build_issues.json length == 0`

#### Score Gen2 Cloud Run Service Health in GCP Project `${GCP_PROJECT_ID}`

Scores 1 if all gen2 backing Cloud Run services are Ready with traffic on the latest revision.

- **Robot task name**: <code>Score Gen2 Cloud Run Service Health in GCP Project `${GCP_PROJECT_ID}`</code>
- **Sub-metric names**: `gen2_run_health`, `gen2_unhealthy_service_count`
- **Underlying script**: `check_gen2_run_health.sh`
- **Tags**: `gcloud`, `function`, `cloudrun`, `gcp`, `${GCP_PROJECT_ID}`, `data:config`
- **Pass condition**: `gen2_run_health_issues.json length == 0`

## Inputs

| Name | Type | Description | Default | Required |
|---|---|---|---|---|
| `GCP_PROJECT_ID` | string | The GCP Project ID to scope the API to. | — | yes |

## Secrets

| Name | Description | Required |
|---|---|---|
| `gcp_credentials` | GCP service account json used to authenticate with GCP APIs. | yes |

## Outputs

- Binary monitor health score (`0` or `1`) pushed by `sli.robot`
- Sub-metrics per health dimension with raw issue counts
- `function_config_report.json`
- `function_config_issues.json`
- `function_iam_issues.json`
- `gen2_run_health_report.json`
- `gen2_run_health_issues.json`
- `function_build_issues.json`
- `function_scaling_issues.json`

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
bash fetch_function_config.sh
bash check_function_iam.sh
bash check_gen2_run_health.sh
bash check_function_builds.sh
bash check_function_scaling.sh
```

## Source files

- `runbook.robot` — orchestrates tools and raises issues
- `sli.robot` — binary multi-dimensional monitor scoring
- `cloud_functions_next_steps.sh` — maps error messages to recommended next steps
- `fetch_function_config.sh` — fetches function configurations, flags default service accounts
- `check_function_iam.sh` — detects publicly invocable functions
- `check_gen2_run_health.sh` — checks gen2 Cloud Run service health
- `check_function_builds.sh` — detects failed deployments and builds
- `check_function_scaling.sh` — reviews scaling and timeout configuration
