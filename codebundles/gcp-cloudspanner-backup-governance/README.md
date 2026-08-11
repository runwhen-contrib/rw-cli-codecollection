# GCP Cloud Spanner Backup & Data Protection

Monitors the data-protection and configuration governance posture of GCP Cloud Spanner — backup existence/recency, backup expiration, point-in-time-recovery (PITR) retention, deletion protection, IAM access, and encryption (CMEK). Helps operators ensure Spanner databases are recoverable and not exposed to accidental deletion or overly-permissive access.

## Overview

- **Backup Existence & Recency**: Lists backups per database and flags databases with no backup or whose most recent backup is older than the recency threshold.
- **Backup Expiration**: Inspects each backup's `expire_time` and flags backups already expired or expiring within the warning window, leaving retention gaps.
- **PITR Configuration**: Reads each database's `version_retention_period` (e.g. `1h`, `7d`) and flags databases below the recommended minimum PITR window.
- **Deletion Protection**: Flags instances and databases with deletion protection (`enableDropProtection`) disabled, which risks accidental data loss.
- **IAM Access**: Reviews IAM policy on instances and databases for public bindings (`allUsers`, `allAuthenticatedUsers`) and overly-permissive primitive roles (`roles/owner`, `roles/editor`).
- **Encryption Configuration**: Reports whether each database uses Google-managed or customer-managed encryption (CMEK) and flags deviations from the required encryption policy.
- **Data Protection Summary**: Produces a consolidated per-database JSON summary of backup recency, PITR window, deletion protection, IAM exposure, and encryption, with an overall verdict (healthy/warning/critical).

## Configuration

### Required Variables

- `GCP_PROJECT_ID`: GCP Project ID containing the Cloud Spanner instances.

### Optional Variables

- `BACKUP_RECENCY_THRESHOLD_HOURS`: Max age (hours) of the most recent backup before an issue is raised (default: `24`).
- `BACKUP_EXPIRY_WARNING_DAYS`: Warn if a backup expires within this many days (default: `3`).
- `PITR_MINIMUM_DAYS`: Minimum recommended point-in-time-recovery retention, in days (default: `1`).
- `REQUIRE_CMEK`: If `true`, flag databases not using customer-managed encryption (default: `false`).

### Secrets

- `gcp_credentials`: GCP service account JSON key for authentication. Format: JSON object containing `type`, `project_id`, `private_key_id`, `private_key`, `client_email`, `client_id`, `auth_uri`, `token_uri`. Requires `roles/spanner.viewer` and `roles/spanner.backupViewer` (or `roles/spanner.admin` for full visibility into IAM policies and backups).

## Tasks Overview

### Check Cloud Spanner Backup Existence and Recency
Lists backups per database (matched via each backup's `database` field) and flags databases with no backup at all, or whose most recent backup's `create_time` is older than `BACKUP_RECENCY_THRESHOLD_HOURS`.

### Check Cloud Spanner Backup Expiration
Inspects each backup's `expire_time` and flags backups that have already expired, or that expire within `BACKUP_EXPIRY_WARNING_DAYS`, which would leave a retention gap.

### Check Cloud Spanner Point-in-Time Recovery Configuration
Describes each database and parses `version_retention_period` (formatted like `1h` or `7d`) into days, flagging databases whose PITR window is below `PITR_MINIMUM_DAYS`.

### Check Cloud Spanner Deletion Protection
Checks `enableDropProtection` at both the instance level (where the field is present in the API response) and the database level (defaulting to disabled if absent, matching the API default), flagging any resource with protection disabled.

### Check Cloud Spanner IAM Access Configuration
Reads the IAM policy on each instance and database and flags bindings that grant access to `allUsers`/`allAuthenticatedUsers`, or that bind the primitive `roles/owner`/`roles/editor` roles directly.

### Check Cloud Spanner Encryption Configuration
Describes each database and checks `encryptionConfig.kmsKeyName`. Absence means Google-managed (default) encryption. Only raises an issue when `REQUIRE_CMEK=true` and no CMEK key is configured.

### Generate Cloud Spanner Data Protection Summary
Recomputes all of the above dimensions per database and writes a consolidated JSON summary with an overall verdict, raising a rollup issue for any non-healthy database.

## SLI

`sli.robot` produces a 0-1 data-protection score aggregating six dimensions: backup recency, backup expiration, PITR configuration, deletion protection, IAM access, and encryption (each a binary pass/fail, averaged). The consolidated summary task is runbook-only (deep investigation), not part of the SLI, to keep the SLI lightweight.

## Requirements

The following GCP IAM roles are required on the service account:
- `roles/spanner.viewer`
- `roles/spanner.backupViewer` (or included in `roles/spanner.admin`)

Reading IAM policies via `get-iam-policy` additionally requires `resourcemanager.projects.getIamPolicy`-equivalent Spanner permissions, typically granted by `roles/spanner.admin` or `roles/iam.securityReviewer`.

## Platform Tools

- `gcloud spanner` - Google Cloud CLI Spanner commands
- `jq` - JSON processor
- `python3` - Python runtime (duration parsing, date arithmetic, numeric formatting)

## Notes / Assumptions

- **Resource type**: The `gcp_spanner_instances` identifier in `.runwhen/generation-rules/` is used **only by RunWhen Local** for auto-discovery/SLX generation (the CloudQuery table name RunWhen Local matches against when indexing a project). The runbook and SLI scripts do **not** use it — they discover instances directly via `gcloud spanner instances list --project=$GCP_PROJECT_ID`, so the CodeBundle runs standalone against any GCP project with no RunWhen Local dependency.
- **Backup-to-database matching**: `gcloud spanner backups list --instance=<id>` returns each backup's `database` field as the full resource path of the source database at backup time; scripts match backups to databases on this field.
- **PITR parsing**: `version_retention_period` is returned as a duration string (e.g. `1h`, `7d`, `3600s`) and is parsed into days for comparison against `PITR_MINIMUM_DAYS`.
- **Deletion protection field availability**: `enableDropProtection` is a well-established field on Cloud Spanner databases (default `false` if unset). Its presence on the instance resource depends on the Spanner API version in use; the instance-level check is skipped gracefully (not flagged as an issue) when the field is absent from `gcloud spanner instances describe` output, per the design spec's "check both where available" guidance.
- **Encryption**: Only databases are checked for CMEK (`encryptionConfig.kmsKeyName`); instance-level encryption configuration is not part of the Spanner API. Encryption issues are only raised when `REQUIRE_CMEK=true`.
- **Sibling bundle**: `gcp-cloudspanner-instance-health` covers live operational health (CPU, storage, latency, instance/database state); this bundle covers backups, PITR, deletion protection, IAM, and encryption. The two are complementary and share the same GCP auth pattern.
