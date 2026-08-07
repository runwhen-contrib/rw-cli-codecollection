# GCP Apigee API Proxy Health - Test Infrastructure

## Overview

This test infrastructure provisions an Apigee organization and environments for
testing the `gcp-apigee-proxy-health` CodeBundle.

## Test Scenarios

The bundle is org-scoped and produces one SLX per Apigee organization. The
fixtures cover both healthy and at-risk environments:

| Fixture | State | Purpose |
|---|---|---|
| `google_apigee_organization` | healthy org | Discovery + org-scope target for the bundle |
| `test-env-*` | populated | Environment that hosts deployments |
| `empty-env-*` | empty | Environment with zero deployments (should be flagged for coverage) |

`check_deployments.sh`, `check_revisions.sh`, and `check_environment_coverage.sh`
consume the Apigee Admin API; `check_runtime_status.sh` consults the
`apigee.googleapis.com/environment/active` Cloud Monitoring metric, which
reflects real runtime state.

## Prerequisites

1. GCP project with the Apigee API enabled.
2. Service account with the Apigee Admin API permissions
   (`apigee.apiproxyrevisions.read`, `apigee.environments.list`) and, for the
   runtime-status check, `roles/monitoring.viewer`.
3. `terraform`, `gcloud`, `docker`, `jq`, `yq`, `ajv`, `curl` CLI tools.

## Setup

1. Create `terraform/tf.secret` with:
   ```
   export GOOGLE_APPLICATION_CREDENTIALS="/path/to/service-account-key.json"
   export TF_VAR_project_id="your-gcp-project-id"
   ```
   and place the same key at `.test/gcp.json.secret` for RunWhen Local.

2. Build the fixtures:
   ```bash
   task build-infra
   ```

3. Generate config + run discovery + validate rules:
   ```bash
   task generate-rwl-config GCP_PROJECT_ID=my-gcp-project APIGEE_ORG=my-apigee-org RW_WORKSPACE=my-workspace
   task run-rwl-discovery
   task validate-generation-rules
   ```

4. Review rendered templates under `output/workspaces/`.

5. Tear everything down:
   ```bash
   task clean
   ```
