# GCP Cloud Spanner Backup & Data Protection - Test Infrastructure

## Overview

This test infrastructure creates GCP Cloud Spanner instances, databases, and a backup for testing the `gcp-cloudspanner-backup-governance` CodeBundle.

## Test Scenarios

### protected_database
- Small regional Spanner instance (100 processing units, the minimum tier) in `regional-<region>`.
- One database (`protected_db_<suffix>`) with:
  - `enable_drop_protection = true` (the real API-level `enableDropProtection` field).
  - `version_retention_period = "3d"` (above the default `PITR_MINIMUM_DAYS` of 1).
- A backup (`protected-backup-<suffix>`) created immediately alongside the database, expiring 30 days out.
- Expected issues: `0`.

### unprotected_database
- Regional Spanner instance also provisioned at the minimum tier (100 processing units).
- One database (`unprotected_db_<suffix>`) with:
  - `enable_drop_protection = false`.
  - `version_retention_period = "3d"` (kept adequate so only backup-recency and deletion-protection are exercised).
- No backup is created for this database.
- Expected issues: `2` (severities `2` for deletion protection disabled, `3` for no backup found).

## Prerequisites

1. GCP project with the Cloud Spanner API enabled.
2. Service account with permissions to create Cloud Spanner instances, databases, and backups (`roles/spanner.admin` for provisioning; the CodeBundle itself only needs `roles/spanner.viewer` + `roles/spanner.backupViewer` at runtime).
3. `gcloud` CLI configured.

## Setup

1. Create `terraform/tf.secret` with:
   ```
   export GOOGLE_APPLICATION_CREDENTIALS="/path/to/service-account-key.json"
   export TF_VAR_project_id="your-gcp-project-id"
   ```

2. Run:
   ```bash
   task build-infra
   ```

3. Clean up when done:
   ```bash
   task clean
   ```

   Note: `check-and-cleanup-terraform` first disables `enable_drop_protection` on the protected database via `gcloud spanner databases update --no-enable-drop-protection` before running `terraform destroy`, since a real API-level drop-protected database cannot otherwise be deleted.
