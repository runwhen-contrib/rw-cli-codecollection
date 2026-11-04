# GCP Project Configuration Audit - Test Infrastructure

## Overview

This test infrastructure provisions GCP resources to exercise the `gcp-project-configuration-audit` CodeBundle's detection capabilities across its four detection dimensions.

## Test Scenarios

### clean_project
- Admin activity, data access, and policy denied audit logging configured
- No IAM policy changes in the lookback window
- No org policy violations
- Sparse PERMISSION_DENIED logs

### public_bucket_access_allowed
- Project org policy `storage.publicAccessPrevention` set to `not enforced`, triggering a violation detected by the org-policy task

### audit_logging_disabled
- Project with no audit config or no log sink, raising a coverage-gap issue

## Prerequisites

1. GCP project with Cloud Logging API and Cloud Resource Manager API enabled
2. Service account with permissions to create org policies, sinks, and read IAM policies
3. `gcloud` CLI and `terraform` configured

## Setup

1. Create `terraform/tf.secret` with:
   ```
   export GOOGLE_APPLICATION_CREDENTIALS="/path/to/service-account-key.json"
   export TF_VAR_project_id="your-gcp-project-id"
   export TF_VAR_org_id="your-org-id"
   ```

2. Run:
   ```bash
   task build-infra
   ```
