---
name: gcp-cloudspanner-backup-governance
kind: skill-template
description: Monitors GCP Cloud Spanner data-protection and governance posture — backup existence/recency, backup expiration, PITR retention, deletion protection, IAM access, and CMEK encryption. Use when auditing or monitoring Cloud Spanner backup and data-protection compliance.
runtime:
  runbook: runbook.robot
  monitor: sli.robot
  executor: worker
  entrypoint: /home/runwhen/robot-runtime/runrobot.sh
  base_image: rw-base-runtime
platforms: [GCP, Spanner]
resource_types: [gcp_resource]
access: read-only
---

# GCP Cloud Spanner Backup & Data Protection

## Summary

Monitors the data-protection and configuration governance posture of GCP Cloud Spanner — backup existence/recency, backup expiration, point-in-time-recovery (PITR) retention, deletion protection, IAM access, and encryption (CMEK).

See [README.md](README.md) for additional context.

## Tools

### Check Cloud Spanner Backup Existence and Recency for `${GCP_PROJECT_ID}`

Lists backups per database and flags databases with no backup or whose most recent backup is older than the recency threshold.

- **Robot task name**: <code>Check Cloud Spanner Backup Existence and Recency for `${GCP_PROJECT_ID}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `check_backup_recency.sh`
- **Tags**: `gcp`, `spanner`, `backup`, `recency`, `data:config`, `access:read-only`
- **Reads**: —
- **Writes**: `backup_recency_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Check Cloud Spanner Backup Expiration for `${GCP_PROJECT_ID}`

Inspects backup expire_time and flags backups already expired or expiring within the warning window, leaving retention gaps.

- **Robot task name**: <code>Check Cloud Spanner Backup Expiration for `${GCP_PROJECT_ID}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `check_backup_expiration.sh`
- **Tags**: `gcp`, `spanner`, `backup`, `expiration`, `data:config`, `access:read-only`
- **Reads**: —
- **Writes**: `backup_expiration_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Check Cloud Spanner Point-in-Time Recovery Configuration for `${GCP_PROJECT_ID}`

Reads each database's version_retention_period and flags databases below the recommended PITR window.

- **Robot task name**: <code>Check Cloud Spanner Point-in-Time Recovery Configuration for `${GCP_PROJECT_ID}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `check_pitr_config.sh`
- **Tags**: `gcp`, `spanner`, `database`, `pitr`, `data:config`, `access:read-only`
- **Reads**: —
- **Writes**: `pitr_config_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Check Cloud Spanner Deletion Protection for `${GCP_PROJECT_ID}`

Flags instances and databases with deletion protection disabled, which risks accidental data loss.

- **Robot task name**: <code>Check Cloud Spanner Deletion Protection for `${GCP_PROJECT_ID}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `check_deletion_protection.sh`
- **Tags**: `gcp`, `spanner`, `instance`, `database`, `deletion-protection`, `data:config`, `access:read-only`
- **Reads**: —
- **Writes**: `deletion_protection_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Check Cloud Spanner IAM Access Configuration for `${GCP_PROJECT_ID}`

Reviews IAM policy on instances/databases for public bindings (allUsers, allAuthenticatedUsers) and overly-permissive primitive roles.

- **Robot task name**: <code>Check Cloud Spanner IAM Access Configuration for `${GCP_PROJECT_ID}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `check_iam_access.sh`
- **Tags**: `gcp`, `spanner`, `instance`, `database`, `iam`, `data:config`, `access:read-only`
- **Reads**: —
- **Writes**: `iam_access_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Check Cloud Spanner Encryption Configuration for `${GCP_PROJECT_ID}`

Reports whether each database uses Google-managed or customer-managed encryption (CMEK) and flags deviations from the required encryption policy.

- **Robot task name**: <code>Check Cloud Spanner Encryption Configuration for `${GCP_PROJECT_ID}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `check_encryption_config.sh`
- **Tags**: `gcp`, `spanner`, `database`, `encryption`, `cmek`, `data:config`, `access:read-only`
- **Reads**: —
- **Writes**: `encryption_config_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


## Monitor

Measures the data-protection posture of Cloud Spanner databases by scoring backup recency, backup expiration, PITR configuration, deletion protection, IAM access, and encryption. Produces a value between 0 (completely failing) and 1 (fully passing).

- **Robot file**: `sli.robot`
- **Score range**: `0.0` (failing) to `1.0` (healthy)
- **Aggregation**: arithmetic mean of the sub-checks below
- **Recommended interval**: `180s`

### Sub-checks

#### Score Cloud Spanner Backup Recency for `${GCP_PROJECT_ID}`

Scores backup existence and recency. Returns 1 if every database has a backup no older than the recency threshold.

- **Robot task name**: <code>Score Cloud Spanner Backup Recency for `${GCP_PROJECT_ID}`</code>
- **Sub-metric name**: `backup_recency`
- **Underlying script**: `check_backup_recency.sh`
- **Tags**: `gcp`, `spanner`, `backup`, `recency`, `data:config`, `access:read-only`
- **Reads**: —
- **Pass condition**: `int(${issues_output.stdout}) == 0`


#### Score Cloud Spanner Backup Expiration for `${GCP_PROJECT_ID}`

Scores backup expiration exposure. Returns 1 if no backup is expired or expiring within the warning window.

- **Robot task name**: <code>Score Cloud Spanner Backup Expiration for `${GCP_PROJECT_ID}`</code>
- **Sub-metric name**: `backup_expiration`
- **Underlying script**: `check_backup_expiration.sh`
- **Tags**: `gcp`, `spanner`, `backup`, `expiration`, `data:config`, `access:read-only`
- **Reads**: —
- **Pass condition**: `int(${issues_output.stdout}) == 0`


#### Score Cloud Spanner PITR Configuration for `${GCP_PROJECT_ID}`

Scores point-in-time-recovery configuration. Returns 1 if every database meets the minimum PITR window.

- **Robot task name**: <code>Score Cloud Spanner PITR Configuration for `${GCP_PROJECT_ID}`</code>
- **Sub-metric name**: `pitr_config`
- **Underlying script**: `check_pitr_config.sh`
- **Tags**: `gcp`, `spanner`, `database`, `pitr`, `data:config`, `access:read-only`
- **Reads**: —
- **Pass condition**: `int(${issues_output.stdout}) == 0`


#### Score Cloud Spanner Deletion Protection for `${GCP_PROJECT_ID}`

Scores deletion protection coverage. Returns 1 if no instance or database has deletion protection disabled.

- **Robot task name**: <code>Score Cloud Spanner Deletion Protection for `${GCP_PROJECT_ID}`</code>
- **Sub-metric name**: `deletion_protection`
- **Underlying script**: `check_deletion_protection.sh`
- **Tags**: `gcp`, `spanner`, `instance`, `database`, `deletion-protection`, `data:config`, `access:read-only`
- **Reads**: —
- **Pass condition**: `int(${issues_output.stdout}) == 0`


#### Score Cloud Spanner IAM Access Configuration for `${GCP_PROJECT_ID}`

Scores IAM exposure. Returns 1 if no public bindings or overly-permissive primitive roles are found.

- **Robot task name**: <code>Score Cloud Spanner IAM Access Configuration for `${GCP_PROJECT_ID}`</code>
- **Sub-metric name**: `iam_access`
- **Underlying script**: `check_iam_access.sh`
- **Tags**: `gcp`, `spanner`, `instance`, `database`, `iam`, `data:config`, `access:read-only`
- **Reads**: —
- **Pass condition**: `int(${issues_output.stdout}) == 0`


#### Score Cloud Spanner Encryption Configuration for `${GCP_PROJECT_ID}`

Scores encryption policy compliance. Returns 1 if no database violates the configured CMEK requirement.

- **Robot task name**: <code>Score Cloud Spanner Encryption Configuration for `${GCP_PROJECT_ID}`</code>
- **Sub-metric name**: `encryption_config`
- **Underlying script**: `check_encryption_config.sh`
- **Tags**: `gcp`, `spanner`, `database`, `encryption`, `cmek`, `data:config`, `access:read-only`
- **Reads**: —
- **Pass condition**: `int(${issues_output.stdout}) == 0`


## Inputs

| Name | Type | Description | Default | Required |
|---|---|---|---|---|
| `GCP_PROJECT_ID` | string | GCP Project ID containing the Cloud Spanner instances. | — | yes |
| `BACKUP_RECENCY_THRESHOLD_HOURS` | string | Max age (hours) of the most recent backup before an issue is raised. | `24` | no |
| `BACKUP_EXPIRY_WARNING_DAYS` | string | Warn if a backup expires within this many days. | `3` | no |
| `PITR_MINIMUM_DAYS` | string | Minimum recommended point-in-time-recovery retention (days). | `1` | no |
| `REQUIRE_CMEK` | string | If 'true', flag databases not using customer-managed encryption. | `false` | no |

## Secrets

| Name | Description | Required |
|---|---|---|
| `gcp_credentials` | GCP service account JSON key used to authenticate with GCP APIs. Requires Spanner Viewer and Spanner Backup Viewer roles. | yes |

## Outputs

- Monitor health score (`0.0`–`1.0`) pushed by `sli.robot`
- `backup_recency_issues.json`
- `backup_expiration_issues.json`
- `pitr_config_issues.json`
- `deletion_protection_issues.json`
- `iam_access_issues.json`
- `encryption_config_issues.json`

## How to invoke

### Production (RunWhen runner / worker)

The platform **runner** schedules work on a location **worker**. The worker
image (`rw-base-runtime`) executes Robot via `runrobot.sh` with
`RW_PATH_TO_ROBOT` set to the bound path under `/home/runwhen/collection/`.

- **Runbook**: `codebundles/gcp-cloudspanner-backup-governance/runbook.robot`
- **Monitor**: `codebundles/gcp-cloudspanner-backup-governance/sli.robot`

### Local development (devcontainer only)

`ro` is a dev-time wrapper in `codecollection-devtools` — not the enterprise runtime.

```bash
cd codebundles/gcp-cloudspanner-backup-governance
export GCP_PROJECT_ID=...
export BACKUP_RECENCY_THRESHOLD_HOURS=...
export BACKUP_EXPIRY_WARNING_DAYS=...
export PITR_MINIMUM_DAYS=...
export REQUIRE_CMEK=...
ro runbook.robot
```

### Standalone scripts (no Robot)


Set the input variables above, then run the matching script:

```bash
cd codebundles/gcp-cloudspanner-backup-governance
export GCP_PROJECT_ID=...
export BACKUP_RECENCY_THRESHOLD_HOURS=...
export BACKUP_EXPIRY_WARNING_DAYS=...
bash check_backup_expiration.sh
bash check_backup_recency.sh
bash check_deletion_protection.sh
bash check_encryption_config.sh
bash check_iam_access.sh
bash check_pitr_config.sh
```

## Source files

- `runbook.robot` — orchestrates tools and raises issues
- `sli.robot` — monitor scoring (`sli.robot` runtime file)
- `check_backup_expiration.sh` — Bash helper script `check_backup_expiration.sh`.
- `check_backup_recency.sh` — Bash helper script `check_backup_recency.sh`.
- `check_deletion_protection.sh` — Bash helper script `check_deletion_protection.sh`.
- `check_encryption_config.sh` — Bash helper script `check_encryption_config.sh`.
- `check_iam_access.sh` — Bash helper script `check_iam_access.sh`.
- `check_pitr_config.sh` — Bash helper script `check_pitr_config.sh`.
