# GCP Project Quota Health - Test Infrastructure

## Overview

This test infrastructure validates the `gcp-project-quota-health` CodeBundle
against a GCP project. Because quota monitoring is a project-level, read-only
check (allocation quotas, rate quotas, and Cloud Logging rejection events), no
discrete test resources are provisioned. The test validates that the service
account has API access and that the bundle's analysis scripts run and emit
graceful, well-formed output.

## Test Scenarios

### healthy_project
- All quota usage below `QUOTA_WARNING_THRESHOLD`; no throttling or rejection events in the lookback window.
- Expected issues: 0 across all four tasks.

### quota_approaching_limit
- A single allocation quota whose usage exceeds `QUOTA_WARNING_THRESHOLD`.
- Expected issues: 2 (one from the allocation task, one from the quota threshold task), severities `[3, 3]`.

### rate_throttling
- A rate quota near/over limit with throttling and rejection events present in Cloud Logging.
- Expected issues: 3, severities `[3, 4, 4]`.

> The exact issue counts depend on live Cloud Monitoring, Service Usage, and
> Cloud Logging data in the target project. The scripts degrade gracefully and
> emit empty issue lists when no data is available rather than failing.

## Prerequisites

1. GCP project with the Service Usage, Cloud Monitoring, and Cloud Logging APIs enabled.
2. Service account with permissions to run the bundle:
   - `roles/serviceusage.serviceUsageConsumer`
   - `roles/monitoring.viewer`
   - `roles/logging.viewer`
3. `gcloud` CLI, `curl`, `jq`, and `python3` available in the execution environment.

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
