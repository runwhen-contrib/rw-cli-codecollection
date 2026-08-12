# GCP BigQuery Quota Health - Test Infrastructure

## Overview

This test infrastructure creates GCP BigQuery datasets and tables for testing the `gcp-bigquery-quota-health` CodeBundle.

## Test Scenarios

### adequate_capacity
- Small, well-contained single dataset with proper expiration
- Low slot utilization and storage usage
- Well within dataset/table limits
- Expected issues: 0

### capacity_pressure
- Multiple datasets and tables simulating capacity pressure
- Storage approaching quota and dataset/table counts increasing
- Expected issues: 2-3 (storage and dataset/table limit warnings)

> Note: Slot utilization and daily query counts are derived from live
> Cloud Monitoring and INFORMATION_SCHEMA data, which depends on the real
> project activity and reservation configuration. Storage and
> dataset/table count checks are deterministic from the provisioned
> resources.

## Prerequisites

1. GCP project with BigQuery API enabled
2. Service account with permissions to create BigQuery datasets and tables
3. `gcloud` CLI configured
4. Service account used to run the bundle needs `roles/bigquery.admin` or `roles/bigquery.resourceAdmin` plus `roles/monitoring.metrics.list`

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
