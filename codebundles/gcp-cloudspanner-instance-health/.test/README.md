# GCP Cloud Spanner Instance Health - Test Infrastructure

## Overview

This test infrastructure creates GCP Cloud Spanner instances and databases for testing the `gcp-cloudspanner-instance-health` CodeBundle.

## Test Scenarios

### healthy_instance
- Small regional Spanner instance (100 processing units, the minimum tier) in `regional-<region>`.
- One database (`healthy_db_<suffix>`) in READY state with a simple table.
- Low CPU/storage utilization under normal conditions.
- Expected issues: `0`.

### overloaded_instance
- Regional Spanner instance also provisioned at the minimum tier (100 processing units == 0.1 node-equivalent), which yields a small derived storage limit (~410 GB at the default 4096 GB/node from `STORAGE_LIMIT_GB_PER_NODE`).
- One database (`overloaded_db_<suffix>`) in READY state.
- Terraform alone provisions the instance/database shape; it does not generate live traffic. To actually exercise the CPU or storage thresholds against this instance, either:
  1. Run a load-generation script (e.g. a simple loop issuing reads/writes via the Spanner client libraries) against `overloaded-instance-<suffix>` for a few minutes before running the runbook/SLI, to push high-priority CPU utilization above `CPU_UTILIZATION_THRESHOLD`; or
  2. Insert enough rows into `overloaded_db_<suffix>` to approach the derived storage limit, to trigger `STORAGE_UTILIZATION_THRESHOLD`.
- Expected issues: `2` (severities `2`, `3`) once one or both of the above conditions have been driven.

## Prerequisites

1. GCP project with the Cloud Spanner API enabled.
2. Service account with permissions to create Cloud Spanner instances and databases (`roles/spanner.admin` for provisioning; the CodeBundle itself only needs `roles/spanner.viewer` + `roles/monitoring.viewer` at runtime).
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
