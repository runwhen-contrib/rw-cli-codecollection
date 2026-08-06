# GCP BigQuery Dataset Health - Test Infrastructure

## Overview

This test infrastructure creates GCP BigQuery datasets and tables for testing the `gcp-bigquery-dataset-health` CodeBundle.

## Test Scenarios

### well_configured_project
- Datasets with proper default table expiration
- Tables with reasonable sizes
- No public access
- Audit logging enabled

### oversized_tables
- Tables exceeding the size threshold (100 GB)
- Tables without expiration policies

### security_misconfigurations
- Datasets with public access (allUsers)
- No audit logging configured

## Prerequisites

1. GCP project with BigQuery API enabled
2. Service account with permissions to create BigQuery datasets and tables
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