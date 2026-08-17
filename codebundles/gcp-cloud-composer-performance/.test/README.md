# GCP Cloud Composer Performance - Test Infrastructure

## Overview

This test infrastructure provisions a minimal Cloud Composer 3 environment
(`ENVIRONMENT_SIZE_SMALL`, GKE Autopilot) for testing the
`gcp-cloud-composer-performance` CodeBundle. The bundle analyzes worker,
scheduler, and queue utilization pulled from Cloud Monitoring, so test
environments primarily need to exist and be visible via
`gcloud composer environments list` with Monitoring data flowing to them.

## Test Scenarios

### balanced_environment
- A minimal Cloud Composer 3 environment (`ENVIRONMENT_SIZE_SMALL`) with 1
  scheduler, 1 web server, 1-3 workers, and 1 DAG processor, expected to
  report **no** performance issues.

> Note: Creating dedicated "saturated" or "over-provisioned" Composer
> environments is impractical and expensive. These conditions are driven by
> live workload and are evaluated against Cloud Monitoring; the test resource
> provides a real environment against which discovery and metric queries are
> exercised.

## Prerequisites

1. GCP project with the Cloud Composer API (`composer.googleapis.com`)
   enabled.
2. Service account with permissions to create Composer environments and a
   service account.
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

## Cleanup

```bash
task clean
```
