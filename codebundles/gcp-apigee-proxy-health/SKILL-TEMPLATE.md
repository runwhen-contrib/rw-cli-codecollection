---
name: gcp-apigee-proxy-health
kind: skill-template
description: Identify and diagnose GCP Apigee API proxy health problems per organization (deployment state, revision drift, failed deployments, and the Apigee-specific policy_error vs target_error and latency-overhead splits). Use when triaging or monitoring GCP, Apigee workloads.
runtime:
  runbook: runbook.robot
  monitor: sli.robot
  executor: worker
  entrypoint: /home/runwhen/robot-runtime/runrobot.sh
  base_image: rw-base-runtime
platforms: [GCP, Apigee]
resource_types: [project]
access: read-only
---

# GCP Apigee API Proxy Deployment and Traffic Health

## Summary

This CodeBundle monitors the health of Apigee API proxies: whether the intended
proxy revision is actually deployed and serving, whether deployments are
erroring or drifted across environments, and whether request failures originate
INSIDE Apigee (`policy_error`) versus at the backend (`target_error`), plus the
Apigee processing-overhead latency split.

See [README.md](README.md) for additional context.

## Tools

### Apigee Proxy Discovery (suite setup, not a task)

Lists all proxies and their deployments using the org-wide
`/organizations/{org}/deployments` endpoint (ONE call) plus `/apis`, recording per
proxy/environment the deployed revision, state and `errors[]`. Resolves
`APIGEE_ORG` from `GCP_PROJECT_ID` when not supplied.

- **Runs in**: `Suite Initialization` -- it can only report its own failure, so it is setup rather than a task
- **Robot file**: `runbook.robot`
- **Underlying script**: `discover_proxies.sh`
- **Tags**: `gcloud`, `apigee`, `gcp`, `${APIGEE_ORG}`, `access:read-only`, `data:config`
- **Reads**: `GCP_PROJECT_ID`, `APIGEE_ORG`, `PROXIES`, `ENVIRONMENTS`
- **Writes**: `apigee_deployments.json`, `apigee_proxies.json`, `apigee_discovery_issues.json`
- **Issues raised**: authentication or org-resolution failures

### Check Apigee Proxy Deployment Health in `${APIGEE_ORG}`

Verifies every proxy deployment is `READY` with an empty `errors[]`; flags
deployments in `ERROR` or `PROGRESSING` state or reporting errors.

- **Robot task name**: <code>Check Apigee Proxy Deployment Health in `${APIGEE_ORG}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `check_deployment_state.sh`
- **Tags**: `gcloud`, `apigee`, `gcp`, `${APIGEE_ORG}`, `access:read-only`, `data:state`
- **Writes**: `deployment_state_issues.json`

### Check Apigee Deployed Revision vs Expected and Revision Drift in `${APIGEE_ORG}`

Verifies the deployed revision per environment matches the latest revision and
environments do not diverge; flags stale logic live in production and silent
fallback to an older revision after a failed deploy.

- **Underlying script**: `check_revision_drift.sh`
- **Writes**: `revision_drift_issues.json`

### Check Apigee Undeployed and Orphaned Proxies in `${APIGEE_ORG}`

Detects failed deployments (revision in ERROR, newer revision not replacing an
older one) and proxies not deployed to any environment.

- **Underlying script**: `check_failed_deployments.sh`
- **Writes**: `failed_deployments_issues.json`

### Check Apigee Proxy Revision Housekeeping in `${APIGEE_ORG}`

Flags proxies accumulating many superseded/undeployed revisions (severity 4).

- **Underlying script**: `check_revision_accumulation.sh`
- **Writes**: `revision_accumulation_issues.json`

### Analyze Apigee policy_error vs target_error Split in `${APIGEE_ORG}`

Queries Analytics (dimension `apiproxy`) for `sum(is_error)`, `sum(policy_error)`,
`sum(target_error)`, `sum(message_count)`; flags `policy_error` and `target_error`
rates each against their own threshold.

- **Underlying script**: `analyze_error_split.sh`
- **Writes**: `error_split_issues.json`

### Analyze Apigee Latency and Processing Overhead in `${APIGEE_ORG}`

Flags p95 `total_response_time` above `LATENCY_MS_THRESHOLD` and total-minus-target
gap above `OVERHEAD_MS_THRESHOLD` (Apigee processing overhead).

- **Underlying script**: `analyze_latency_split.sh`
- **Writes**: `latency_split_issues.json`

### Analyze Apigee Auth and Quota Error Elevation in `${APIGEE_ORG}`

Flags elevated 401/403 and 429 rates from `response_status_code` Analytics data.

- **Underlying script**: `analyze_http_error_rates.sh`
- **Writes**: `http_error_rate_issues.json`

### Check Apigee Failed Long-Running Operations in `${GCP_PROJECT_ID}`

Flags management operations that failed in the lookback window.

- **Underlying script**: `check_failed_operations.sh`
- **Writes**: `failed_operations_issues.json`

## Context

- **Shared helper**: `apigee_common.sh` wraps token acquisition, org resolution,
  REST pagination, discovery caching and Analytics stats for this bundle and its
  siblings (`gcp-apigee-environment-health`, `gcp-apigee-product-governance`).
- **Auth**: The `gcp_credentials` secret is activated via `gcloud`; the access
  token authorizes the Apigee REST API (the Analytics stats endpoint is NOT
  exposed by the `gcloud apigee` command group and must be called via REST).
- **Limitations**: Analytics data lags real time (~10 min) and stats queries are
  slow; the SLI is intentionally built on fast management-API checks only.
