# GCP IAM Role Query - Test Infrastructure

## Overview

This test infrastructure provisions GCP resources for exercising the `gcp-iam-role-query` CodeBundle: a service account with documented IAM bindings and a storage bucket for resource-level queries.

## Test Scenarios

### known_service_account
- Service account `gcp-iam-query-test-<suffix>` with two documented project IAM bindings (`roles/storage.objectViewer`, `roles/monitoring.viewer`).
- Expected: no issues, accurate role output matching those bindings.

### unknown_resource
- Query an IAM policy for a resource name that does not exist.
- Expected: one informational (severity 1) issue reporting that no policy was found, without a hard error.

## Prerequisites

1. GCP project with IAM, Resource Manager, and Cloud Storage APIs enabled.
2. Service account with permissions to create service accounts, bind IAM roles, and create storage buckets.
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

3. Run discovery and validation:
   ```bash
   task default
   GOOGLE_APPLICATION_CREDENTIALS=/path/to/key.json bash validate-all-tests.sh
   ```
