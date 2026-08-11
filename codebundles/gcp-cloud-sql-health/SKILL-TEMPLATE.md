---
name: gcp-cloud-sql-health
kind: skill-template
description: Monitor GCP Cloud SQL instance health, configuration, access, and IAM policies. Use when triaging or monitoring GCP, Cloud SQL workloads with skill template `gcp-cloud-sql-health`.
runtime:
  runbook: runbook.robot
  monitor: sli.robot
  executor: worker
  entrypoint: /home/runwhen/robot-runtime/runrobot.sh
  base_image: rw-base-runtime
platforms: [GCP, Cloud SQL]
resource_types: [gcp_resource]
access: read-only
---

# GCP Cloud SQL Health

## Summary

Monitors GCP Cloud SQL instance health covering availability status, configuration, public access/SSL exposure, and IAM policy risks. Helps operators detect availability, security, and configuration problems before they impact applications.

See [README.md](README.md) for additional context.

## Tools

### Check Cloud SQL Instance Status in Project `${GCP_PROJECT_ID}`

Enumerates Cloud SQL instances whose state is not RUNNABLE, including maintenance, failed, or suspended instances, with state messages.

- **Robot task name**: <code>Check Cloud SQL Instance Status in Project `${GCP_PROJECT_ID}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `check_instance_status.sh`
- **Tags**: `gcp`, `cloudsql`, `status`, `data:state-status`, `access:read-only`
- **Reads**: `GCP_PROJECT_ID`, `RESOURCES`
- **Writes**: `instance_status_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when instances are not RUNNABLE

### Fetch Cloud SQL Instance Configurations in Project `${GCP_PROJECT_ID}`

Dumps each instance's configuration (tier, disk, region, zones, database version, maintenance window, backup settings) and flags risky configuration such as low tier, disabled automated backups, or no point-in-time recovery.

- **Robot task name**: <code>Fetch Cloud SQL Instance Configurations in Project `${GCP_PROJECT_ID}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `fetch_instance_config.sh`
- **Tags**: `gcp`, `cloudsql`, `config`, `data:config`, `access:read-only`
- **Reads**: `GCP_PROJECT_ID`, `RESOURCES`, `CONFIG_IMPORTANCE_THRESHOLD`
- **Writes**: `instance_config_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when risky configuration is detected

### Check Cloud SQL Instance Availability and Access in Project `${GCP_PROJECT_ID}`

Flags instances reachable from the public internet or missing SSL enforcement, exposed authorized networks, and instances with IP/environment issues affecting availability.

- **Robot task name**: <code>Check Cloud SQL Instance Availability and Access in Project `${GCP_PROJECT_ID}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `check_instance_access.sh`
- **Tags**: `gcp`, `cloudsql`, `security`, `access`, `data:config-security`, `access:read-only`
- **Reads**: `GCP_PROJECT_ID`, `RESOURCES`
- **Writes**: `instance_access_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when public exposure or access issues are found

### Check Cloud SQL IAM Policies in Project `${GCP_PROJECT_ID}`

Fetches IAM policies for each instance and flags risky bindings including allUsers/allAuthenticatedUsers access and over-broad roles.

- **Robot task name**: <code>Check Cloud SQL IAM Policies in Project `${GCP_PROJECT_ID}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `check_instance_iam.sh`
- **Tags**: `gcp`, `cloudsql`, `iam`, `security`, `data:iam`, `access:read-only`
- **Reads**: `GCP_PROJECT_ID`, `RESOURCES`
- **Writes**: `instance_iam_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when risky IAM bindings are found

## Monitor

This SLI measures the health of GCP Cloud SQL instances by scoring instance status, configuration, availability/access, and IAM policy. Produces a value between 0 (completely failing) and 1 (fully passing).

- **Robot file**: `sli.robot`
- **Score range**: `0.0` (failing) to `1.0` (healthy)
- **Aggregation**: arithmetic mean of the sub-checks below
- **Recommended interval**: `300s`

### Sub-checks

#### Score Cloud SQL Instance Status for `${GCP_PROJECT_ID}`

Scores instance availability. Returns 1 if all instances are RUNNABLE, 0 if any instance is not.

- **Robot task name**: <code>Score Cloud SQL Instance Status for `${GCP_PROJECT_ID}`</code>
- **Sub-metric name**: `instance_status`
- **Underlying script**: `check_instance_status.sh`
- **Tags**: `gcp`, `cloudsql`, `status`, `data:state-status`, `access:read-only`
- **Reads**: `GCP_PROJECT_ID`
- **Pass condition**: no instances in non-RUNNABLE state

#### Score Cloud SQL Instance Configuration for `${GCP_PROJECT_ID}`

Scores instance configuration. Returns 1 if no risky configuration (low tier, backups or PITR disabled) found.

- **Robot task name**: <code>Score Cloud SQL Instance Configuration for `${GCP_PROJECT_ID}`</code>
- **Sub-metric name**: `config`
- **Underlying script**: `fetch_instance_config.sh`
- **Tags**: `gcp`, `cloudsql`, `config`, `data:config`, `access:read-only`
- **Reads**: `GCP_PROJECT_ID`, `CONFIG_IMPORTANCE_THRESHOLD`
- **Pass condition**: no risky configuration issues detected

#### Score Cloud SQL Instance Availability and Access for `${GCP_PROJECT_ID}`

Scores availability and access. Returns 1 if no public exposure, missing SSL, exposed authorized networks, or IP issues.

- **Robot task name**: <code>Score Cloud SQL Instance Availability and Access for `${GCP_PROJECT_ID}`</code>
- **Sub-metric name**: `access`
- **Underlying script**: `check_instance_access.sh`
- **Tags**: `gcp`, `cloudsql`, `security`, `access`, `data:config-security`, `access:read-only`
- **Reads**: `GCP_PROJECT_ID`
- **Pass condition**: no public exposure or access issues detected

#### Score Cloud SQL IAM Policies for `${GCP_PROJECT_ID}`

Scores IAM policy. Returns 1 if no public or over-broad IAM bindings found.

- **Robot task name**: <code>Score Cloud SQL IAM Policies for `${GCP_PROJECT_ID}`</code>
- **Sub-metric name**: `iam`
- **Underlying script**: `check_instance_iam.sh`
- **Tags**: `gcp`, `cloudsql`, `iam`, `security`, `data:iam`, `access:read-only`
- **Reads**: `GCP_PROJECT_ID`
- **Pass condition**: no risky IAM bindings detected

## Inputs

| Name | Type | Description | Default | Required |
|---|---|---|---|---|
| `GCP_PROJECT_ID` | string | GCP Project ID containing the Cloud SQL instances. | — | yes |
| `RESOURCES` | string | Optional comma-separated list of Cloud SQL instance names to scope to. Defaults to `All` (auto-discover all instances). | `All` | no |
| `CONFIG_IMPORTANCE_THRESHOLD` | string | Minimum instance tier vCPU count considered healthy (instances below this are flagged as undersized). | `2` | no |

## Secrets

| Name | Description | Required |
|---|---|---|
| `gcp_credentials` | GCP service account JSON key used to authenticate with GCP APIs. | yes |

## Outputs

- Monitor health score (`0.0`–`1.0`) pushed by `sli.robot`
- Sub-metrics: `instance_status`, `config`, `access`, `iam`
- `instance_status_issues.json`
- `instance_config_issues.json`
- `instance_access_issues.json`
- `instance_iam_issues.json`

## How to invoke

### Production (RunWhen runner / worker)

The platform **runner** schedules work on a location **worker**. The worker
image (`rw-base-runtime`) executes Robot via `runrobot.sh` with
`RW_PATH_TO_ROBOT` set to the bound path under `/home/runwhen/collection/`.

- **Runbook**: `codebundles/gcp-cloud-sql-health/runbook.robot`
- **Monitor**: `codebundles/gcp-cloud-sql-health/sli.robot`

### Local development (devcontainer only)

`ro` is a dev-time wrapper in `codecollection-devtools` — not the enterprise runtime.

```bash
cd codebundles/gcp-cloud-sql-health
export GCP_PROJECT_ID=...
export RESOURCES=All
export CONFIG_IMPORTANCE_THRESHOLD=2
ro runbook.robot
```

### Standalone scripts (no Robot)

Set the input variables above, then run the matching script:

```bash
cd codebundles/gcp-cloud-sql-health
export GCP_PROJECT_ID=...
export RESOURCES=All
export CONFIG_IMPORTANCE_THRESHOLD=2
bash check_instance_status.sh
bash fetch_instance_config.sh
bash check_instance_access.sh
bash check_instance_iam.sh
```

## Source files

- `runbook.robot` — orchestrates tools and raises issues
- `sli.robot` — monitor scoring across four health dimensions
- `check_instance_status.sh` — enumerates instances and flags non-RUNNABLE states
- `fetch_instance_config.sh` — dumps configuration and flags risky settings
- `check_instance_access.sh` — checks public exposure, SSL, authorized networks, and IP issues
- `check_instance_iam.sh` — fetches IAM policies and flags risky bindings
