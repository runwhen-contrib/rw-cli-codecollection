# GCP API Gateway Health

This CodeBundle diagnoses the health of GCP API Gateway (`apigateway.googleapis.com`) and the gateway-to-backend edge, distinguishing faults at the gateway edge from faults in the Cloud Run backends behind it.

> **Important:** This bundle targets **API Gateway**, *not* Apigee. API Gateway and Apigee are different products with different APIs, metrics, and failure modes.

## Overview

The bundle discovers all API Gateway `Api`, `ApiConfig`, and `Gateway` resources dynamically in a project, then analyzes the gateway and the gateway-to-backend relationship across several dimensions:

- **Discovery**: Lists all Api / ApiConfig / Gateway resources plus their states, and dumps a JSON inventory consumed by the other tasks.
- **Resource states**: Flags any Api, ApiConfig, or Gateway in a FAILED (or non-ACTIVE critical) state.
- **Config drift**: Flags gateways pinned to a stale ApiConfig when a newer ACTIVE one exists (stale routes served in production).
- **Managed service**: Confirms each API's managed Service Infrastructure service (`<api-id>-<hash>.apigateway.<project>.cloud.goog`) is enabled.
- **Invoker bindings**: Verifies each gateway's service account holds `roles/run.invoker` on its Cloud Run backends (the most common 403 failure).
- **Backends**: Flags dangling / unreachable `x-google-backend` targets and surfaces 504s near the ESPv2 deadline.
- **Error rates**: Flags elevated 5xx and 401/403 rejection rates via Cloud Monitoring.
- **Latency**: Flags high p95 latency and a large gateway-vs-backend latency gap (isolates ESPv2 overhead).
- **Operations**: Flags failed GCP API Gateway operations.
- **Summary**: Aggregates findings per gateway with an overall verdict and reports single-region (no-failover) advisories.

The bundle deliberately does **not** re-diagnose Cloud Run internals; where evidence points at the backend it hands off to the `gcp-cloudrun-service-health` bundle in `next_steps`.

## Configuration

### Required Variables

- `GCP_PROJECT_ID`: The GCP project ID that hosts the API Gateways to check.

### Optional Variables

- `GCP_REGIONS`: Comma-separated list of regions to search for regional Gateways and operations. (default: `` — empty means discover regions dynamically from the Gateway list)
- `API_NAME`: Restrict analysis to a single API id; empty means all APIs. (default: ``)
- `API_CONFIG_NAME`: Restrict analysis to a single ApiConfig; empty means all. (default: ``)
- `METRIC_LOOKBACK_PERIOD`: Cloud Monitoring lookback period for metric queries, e.g. `3600s`. (default: `3600s`)
- `ERROR_RATE_THRESHOLD`: Maximum acceptable 5xx error ratio as a decimal (`0.01` = 1%). (default: `0.01`)
- `AUTH_ERROR_RATE_THRESHOLD`: Tighter maximum acceptable 401/403 ratio. (default: `0.005`)
- `LATENCY_THRESHOLD_MS`: Maximum acceptable p95 gateway latency in milliseconds. (default: `5000`)
- `LATENCY_GAP_THRESHOLD_MS`: Maximum acceptable gateway-vs-backend latency gap in milliseconds. (default: `1000`)
- `OPERATIONS_LOOKBACK`: Lookback window for failed operations, e.g. `1h` or `24h`. (default: `24h`)
- `ENABLE_SINGLE_REGION_ADVISORY`: Set `true` to emit informational (sev 4) single-region, no-failover findings. (default: `true`)
- `METRIC_TYPE_OVERRIDE`: Optional override for the request-count metric type used by the error-rate and backend checks. Leave empty to resolve the correct metric type at runtime.

### Secrets

- `gcp_credentials`: A GCP service account JSON key. Format is the standard GCP service account JSON object (`type`, `project_id`, `private_key_id`, `private_key`, `client_email`, `client_id`, `auth_uri`, `token_uri`) with the least-privilege IAM roles listed in the Requirements section.

## SLI

This health bundle ships an in-repo `sli.robot` that produces a **weighted composite** 0-1 score (not a binary 0/1 pattern, so one degraded API in a multi-API project does not zero the entire score). Each dimension is pushed as a sub-metric and the weighted total as the primary metric:

| Dimension | Weight |
|---|---|
| `resource_states` | 0.20 |
| `config_drift` | 0.20 |
| `invoker_binding` | 0.20 |
| `managed_service` | 0.15 |
| `error_rate` | 0.15 |
| `latency` | 0.10 |

## Tasks Overview

### Discover GCP API Gateway Apis, Configs and Gateways
Lists all Api, ApiConfig and Gateway resources plus their states using the `gcloud api-gateway` CLI and dumps the JSON inventory consumed by the other tasks. Discovery is dynamic from the project; if it returns nothing, it falls back to the explicit config (project + optional name filters).

### Check GCP API Gateway Resource States
Flags any Api, ApiConfig, or Gateway in a FAILED (or non-ACTIVE critical) state. A FAILED ApiConfig indicates a bad OpenAPI spec or invalid backend address (deploy never took effect); a FAILED Gateway indicates a broken regional deployment.

### Check GCP API Gateway Config Drift
For each Gateway, verifies `gateway.apiConfig` points at the newest ACTIVE ApiConfig for its API. Flags silent drift where a new ApiConfig exists but the Gateway was never updated, so stale routes are served in production.

### Verify API Gateway Managed Service is Enabled
Confirms the API's managed Service Infrastructure service is enabled on the project. A disabled managed service causes every request to fail at the edge with "API not enabled" while the gateway resource looks healthy (total outage).

### Check Gateway Backend Invoker Permissions
For each gateway's deployed ApiConfig, extracts every `x-google-backend` address, resolves the backing Cloud Run service, and verifies the gateway service account holds `roles/run.invoker`. A missing invoker binding causes every request to that route to 403 while gateway and Cloud Run both report healthy. The reusable logic lives in `apigateway_common.sh`.

### Detect Dangling and Unreachable Gateway Backends
Flags backends referenced by `x-google-backend.address` that no longer exist (dangling route) and surfaces 504s where backend latency is near the ESPv2 deadline (too-short deadline for cold starts). Backend-internal evidence hands off to the Cloud Run bundle.

### Analyze GCP API Gateway Error Rates
Queries Cloud Monitoring for gateway request error rates over the lookback window, flagging a 5xx ratio above `ERROR_RATE_THRESHOLD` (backend failing) and a tighter 401/403 ratio above `AUTH_ERROR_RATE_THRESHOLD` (JWT issuer / jwks_uri misconfiguration or API key enforcement).

### Analyze GCP API Gateway Latency
Queries Cloud Monitoring for p95 gateway latency, flagging values above `LATENCY_THRESHOLD_MS` degrades and checking the gateway-vs-backend latency gap (above `LATENCY_GAP_THRESHOLD_MS`) to isolate ESPv2 overhead from a merely slow backend.

### Check for Failed GCP API Gateway Operations
Lists API Gateway operations in the region(s) within `OPERATIONS_LOOKBACK` and flags any in a FAILED state, indicating a provisioning or update that did not take effect.

### Generate GCP API Gateway Health Summary
Aggregates findings from all other checks into a consolidated per-gateway summary (state, config drift, invoker binding, managed service, error rate, latency, operations) with an overall verdict, and reports an informational single-region, no-failover advisory.

## Requirements

The following least-privilege IAM roles are required on the service account:

- `roles/apigateway.viewer`
- `roles/monitoring.viewer`
- `roles/logging.viewer`
- `roles/run.viewer`
- `roles/serviceusage.serviceUsageViewer`
- `run.services.getIamPolicy` (via `roles/iam.securityReviewer` or a custom role) — required for the invoker-binding check

The `gcloud`, `jq`, `curl`, and `bc` CLI tools are required at runtime. The `apigateway.googleapis.com`, `monitoring.googleapis.com`, `run.googleapis.com`, and `serviceusage.googleapis.com` APIs must be enabled for the project.

### Metric type resolution

API Gateway surfaces telemetry through both `apigateway.googleapis.com/proxy/*` (resource `apigateway.googleapis.com/Gateway`) and `serviceruntime.googleapis.com/api/*` (resource `consumed_api` / `produced_api`). Which path carries usable data varies by project, so the error-rate, backend, and latency checks resolve the metric type at runtime from `gcloud monitoring metric-descriptors list` and accept a `METRIC_TYPE_OVERRIDE` rather than hardcoding a type that can silently return an empty series.
