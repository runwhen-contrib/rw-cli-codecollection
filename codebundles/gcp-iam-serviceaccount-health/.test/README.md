# GCP IAM Service Account Health - Test Infrastructure

## Overview

This test infrastructure creates GCP IAM service accounts and IAM bindings for testing the `gcp-iam-serviceaccount-health` CodeBundle.

## Test Scenarios

### healthy_service_accounts
- Service account enabled
- Single recent (rotated) key
- Least-privilege role bindings only
- No privileged project or service-account-level role assignments

### privileged_and_stale_keys
- Service account granted a privileged role (`roles/owner`) at the project level
- Service account with a long-lived (un-rotated) USER_MANAGED key

### excessive_keys
- Service account holding more than `MAX_KEYS_PER_SA` active keys

### disabled_service_account_in_use
- Disabled service account still referenced in project IAM policy bindings (drift)

## Prerequisites

1. GCP project with the IAM API enabled
2. Service account with permissions to create service accounts, keys, and IAM bindings
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

## Expected Issues

The test infrastructure is designed to trigger the following detections:
- `check_privileged_roles.sh`: privileged project-level `roles/owner` binding
- `check_key_rotation.sh` / `check_key_count.sh`: stale and excessive keys
- `check_disabled_service_accounts.sh`: disabled SA still referenced in project IAM policy
