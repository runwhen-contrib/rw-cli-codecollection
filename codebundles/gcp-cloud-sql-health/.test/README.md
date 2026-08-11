# GCP Cloud SQL Health - Test Infrastructure

## Overview

This test infrastructure creates GCP Cloud SQL instances for testing the `gcp-cloud-sql-health` CodeBundle.

## Test Scenarios

### healthy_instance
- Instance is RUNNABLE
- Private IP only (no public exposure)
- SSL enforced
- Automated backups and point-in-time recovery enabled
- Adequate tier (above the vCPU threshold)
- Minimal IAM bindings

### publicly_exposed_instance
- Public IPv4 address enabled (public internet exposure)
- SSL not enforced
- Over-broad IAM binding (allAuthenticatedUsers)
- Expected issues: 3 with severities `[4, 3, 3]`

## Prerequisites

1. GCP project with the Cloud SQL Admin API enabled
2. Service account with permissions to create Cloud SQL instances
3. `gcloud` CLI configured

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
