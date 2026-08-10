# GCP Apigee API Proxy Deployment and Traffic Health

This CodeBundle monitors the health of Apigee API proxies: whether the intended
proxy revision is actually deployed and serving, whether deployments are
erroring or drifted across environments, and -- the highest-value Apigee signal
-- whether request failures originate **inside Apigee** (`policy_error`) versus
at the backend (`target_error`), plus the Apigee processing-overhead latency
split. It lets operators separate a broken proxy from a broken backend during an
incident instead of manually correlating analytics, deployment state and backend
logs.

## Overview

The bundle discovers all proxies and their deployments from the org-wide
`/organizations/{org}/deployments` endpoint (ONE call, respecting management API
rate limits) plus `/apis`, then analyzes them across nine dimensions:

- **Proxy discovery**: Lists all proxies and org-wide deployments (proxy /
  environment / revision / state / errors[]), resolving `APIGEE_ORG` from
  `GCP_PROJECT_ID` when not supplied.
- **Deployment state**: Flags deployments in `ERROR` or `PROGRESSING` state, or
  with a non-empty `errors[]` array.
- **Revision drift**: Flags proxies running an older-than-latest revision (stale
  logic live) and environments that silently diverge across revisions.
- **Failed deployments**: Flags revisions that failed to deploy (ERROR state or
  a newer revision not replacing an older one) and proxies not deployed to any
  environment.
- **Revision housekeeping**: Flags proxies accumulating many superseded /
  undeployed revisions (severity 4).
- **policy_error vs target_error split**: Flags proxies whose `policy_error`
  rate (fault inside the policy chain) and `target_error` rate (backend failing)
  each exceed their own threshold, tracked separately because they route to
  different owners.
- **Latency and processing overhead**: Flags proxies whose p95
  `total_response_time` exceeds `LATENCY_MS_THRESHOLD`, and proxies whose
  total-minus-target gap exceeds `OVERHEAD_MS_THRESHOLD` (Apigee's own
  processing bottleneck vs a slow backend).
- **Auth and quota error rates**: Flags elevated 401/403 (`AUTH_ERROR_RATE_THRESHOLD`)
  and elevated 429 (`RATE_LIMIT_ERROR_THRESHOLD`) rates.
- **Failed long-running operations**: Flags management operations (deployment,
  environment, instance) that failed in the lookback window.

## Configuration

### Required Variables

- `GCP_PROJECT_ID`: The GCP project ID that owns the Apigee organization, used
  for gcloud auth and the Analytics / stats and operations endpoints.

### Optional Variables

- `APIGEE_ORG`: The Apigee organization name (`organizations/{org}`). If empty,
  it is resolved by discovering the Apigee org(s) in `GCP_PROJECT_ID`.
  (default: empty -> auto-resolve)
- `PROXIES`: Comma-separated API proxy names to scope the analysis, or `All`.
  Respects management API rate limits on large orgs. (default: `All`)
- `ENVIRONMENTS`: Comma-separated environment names to scope deployment checks,
  or `All`. (default: `All`)
- `POLICY_ERROR_THRESHOLD`: Maximum acceptable `policy_error` rate
  (`0.01` = 1%). Fault inside Apigee's policy chain. (default: `0.01`)
- `TARGET_ERROR_THRESHOLD`: Maximum acceptable `target_error` rate
  (`0.01` = 1%). Backend failing; hand off to the backend bundle.
  (default: `0.01`)
- `LATENCY_MS_THRESHOLD`: Maximum acceptable p95 `total_response_time` in
  milliseconds. (default: `5000`)
- `OVERHEAD_MS_THRESHOLD`: Maximum acceptable Apigee processing overhead in ms
  (`total_response_time` minus `target_response_time`) before the proxy logic is
  flagged as the bottleneck. (default: `500`)
- `AUTH_ERROR_RATE_THRESHOLD`: Maximum acceptable 401/403 rate
  (`0.02` = 2%). (default: `0.02`)
- `RATE_LIMIT_ERROR_THRESHOLD`: Maximum acceptable 429 rate (`0.05` = 5%).
  (default: `0.05`)
- `ANALYTICS_WINDOW_MIN`: Analytics lookback window in minutes. Analytics data
  lags real time (~10 min), so this is not for a fast SLI. (default: `60`)
- `APIGEE_MAX_STATUS_CALLS`: Maximum per-deployment runtime-status calls
  discovery may make. `state` and `errors[]` are not returned by any deployment
  *list* endpoint, so each deployment needs its own status call; deployments
  beyond this cap are recorded as `UNKNOWN` and reported as such, never as
  healthy. (default: `250`)
- `REVISION_ACCUMULATION_THRESHOLD`: Number of total revisions at which a proxy
  is flagged for housekeeping (severity 4). (default: `20`)

### Secrets

- `gcp_credentials`: A GCP service account JSON key used to authenticate with
  gcloud; the access token obtained from it authorizes the Apigee REST API
  (including the Analytics stats endpoint). Needs `roles/apigee.readOnlyAdmin`,
  `roles/apigee.analyticsViewer` (required for the stats endpoint),
  `roles/monitoring.viewer`, `roles/logging.viewer`. Format is the standard GCP
  service account JSON object (containing `type`, `project_id`, `private_key_id`,
  `private_key`, `client_email`, `client_id`, `auth_uri`, `token_uri`).

## SLI

The SLI produces a continuous 0-1 health score averaged across three fast,
management-API dimensions (each pushed as a sub-metric):

- `deployment_state` -- 1.0 if all deployments are READY with no errors, else 0.0
- `revision_drift` -- 1.0 if all proxies are on their latest revision with no
  cross-environment drift, else 0.0
- `failed_deployments` -- 1.0 if no deployment failed and every proxy is
  deployed, else 0.0

The aggregate is the arithmetic mean of the three dimension scores. The SLI is
deliberately kept to management-API checks because Analytics data lags real time
and stats queries are slow; the deeper `policy_error`/`target_error` and latency
diagnostics live in the runbook, per the SLI authoring guidance.

## Tasks Overview

### Discover Apigee API Proxies and Org-Wide Deployments
Lists all proxies and their deployments from the org-wide deployments endpoint
plus `/apis`, recording per proxy/environment the deployed revision, revision
state and `errors[]`. Resolves `APIGEE_ORG` when not supplied and writes the
discovery snapshot shared by the downstream tasks.

### Check Apigee Proxy Deployment Health
For each deployment, verifies state is `READY` with an empty `errors[]` array;
flags deployments in `ERROR` or `PROGRESSING` state or reporting errors, meaning
the deploy did not take full effect.

### Check Apigee Deployed Revision vs Expected and Revision Drift
Verifies the deployed revision per environment matches the latest revision and
that environments do not diverge; flags stale logic live in production and
environments that silently fell back to an older revision after a failed deploy.

### Check Apigee Failed Deployments and Undeployed Proxies
Detects revisions whose deployment failed and proxies that are expected but not
deployed to any environment, flagging orphaned or stuck proxies after a failed
deploy.

### Check Apigee Proxy Revision Housekeeping
Identifies proxies accumulating many undeployed/superseded revisions without
cleanup (severity 4), preventing drift and deploy confusion over time.

### Analyze Apigee policy_error vs target_error Split
Queries the Analytics stats endpoint (dimension `apiproxy`) for
`sum(is_error)`, `sum(policy_error)`, `sum(target_error)`, `sum(message_count)`.
Flags proxies whose `policy_error` rate and `target_error` rate each exceed their
own threshold, tracked separately because `policy_error` is a proxy-policy-chain
problem and `target_error` is a backend (hand off) problem.

### Analyze Apigee Latency and Processing Overhead
Queries `avg`/percentile `total_response_time` and `target_response_time`.
Flags proxies whose p95 `total_response_time` exceeds `LATENCY_MS_THRESHOLD`, and
proxies whose total-minus-target gap exceeds `OVERHEAD_MS_THRESHOLD` -- isolating
a proxy-logic bottleneck from a merely slow backend.

### Analyze Apigee Auth and Quota Error Elevation
Queries Analytics by `response_status_code` for 401/403/429 rates. Flags
elevated 401/403 (token validation failure, API product mismatch, expired
developer app credentials) and elevated 429 beyond the intended quota /
spike-arrest policy.

### Check Apigee Failed Long-Running Operations
Lists long-running operations in the lookback window and flags any that failed
(deployment, environment change, or instance operation that errored).

## Requirements

The service account needs the following IAM permissions (via
`roles/apigee.readOnlyAdmin` plus `roles/apigee.analyticsViewer`, and
`roles/monitoring.viewer` / `roles/logging.viewer` where needed):

- `apigee.deployments.list`
- `apigee.proxies.list`
- `apigee.proxyrevisions.list`
- `apigee.environments.list`
- `apigee.environments.getStats`
- `apigee.environments.get`
- `apigee.organizations.list` / org get
- `apigee.operations.list`

The `gcloud`, `curl`, and `jq` CLI tools are required at runtime, and the Apigee
Management API (`apigee.googleapis.com`) must be enabled. Analytics metric and
dimension names are org-specific -- verify them against
`/organizations/{org}/environments/{env}/analytics/admin/schemav2` before
relying on a specific metric; a wrong metric name returns an empty series and
fails silently.
