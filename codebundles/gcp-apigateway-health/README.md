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

No SLO is generated for this SLX. The SLI publishes the composite score and each sub-metric, so an objective can be attached later once there is real traffic to calibrate one against — picking a target before that would be guesswork. This matches most bundles in the collection, which ship an SLI without an SLO.

## Tasks Overview

### Discover GCP API Gateway Apis, Configs and Gateways
Lists all Api, ApiConfig and Gateway resources plus their states using the `gcloud api-gateway` CLI and dumps the JSON inventory consumed by the other tasks. Discovery is dynamic from the project; if it returns nothing, it falls back to the explicit config (project + optional name filters).

Discovery must run before any other check, and it always writes the inventory file — including when it finds nothing. Every other check therefore treats a *missing* inventory as an error rather than as an empty project, since an empty inventory would make each check iterate nothing and report clean. The runbook runs discovery as its first task; the SLI runs it during suite setup.

A gateway's region is parsed from its resource name (`projects/*/locations/<region>/gateways/*`) — the `Gateway` resource carries no location field — and each Api's `managedService` is captured here, since that is what scopes the `serviceruntime` metric queries.

### Check GCP API Gateway Resource States
Flags any Api, ApiConfig, or Gateway in a FAILED (or non-ACTIVE critical) state. A FAILED ApiConfig indicates a bad OpenAPI spec or invalid backend address (deploy never took effect); a FAILED Gateway indicates a broken regional deployment.

### Check GCP API Gateway Config Drift
For each Gateway, verifies `gateway.apiConfig` points at the newest ACTIVE ApiConfig for its API. Flags silent drift where a new ApiConfig exists but the Gateway was never updated, so stale routes are served in production.

### Verify API Gateway Managed Service is Enabled
Confirms the API's managed Service Infrastructure service is enabled on the project. A disabled managed service causes every request to fail at the edge with "API not enabled" while the gateway resource looks healthy (total outage).

### Check Gateway Backend Invoker Permissions
For each gateway's deployed ApiConfig, extracts every `x-google-backend` address, resolves the backing Cloud Run service, and verifies the gateway service account holds `roles/run.invoker`. A missing invoker binding causes every request to that route to 403 while gateway and Cloud Run both report healthy. The reusable logic lives in `apigateway_common.sh`.

Three details this check depends on, each of which silently produces "no issues" if got wrong:

- The gateway identity is `gatewayServiceAccount` on the **ApiConfig** — the `Gateway` resource has no service-account field at all.
- That value may be returned either as a bare email or as a resource path (`projects/-/serviceAccounts/<email>`), while IAM policy members are always `serviceAccount:<email>`. Both sides are normalised before comparison.
- The spec is only returned by `api-configs describe --view=FULL`; the default `BASIC` view omits `openapiDocuments` entirely, yielding zero backends to check.

A backend bound to `allUsers` or `allAuthenticatedUsers` is treated as satisfying the requirement, since either genuinely permits the gateway to invoke it.

### Detect Dangling and Unreachable Gateway Backends
Flags backends referenced by `x-google-backend.address` that no longer exist (dangling route) and surfaces 504s where backend latency is near the ESPv2 deadline (too-short deadline for cold starts). Backend-internal evidence hands off to the Cloud Run bundle.

### Analyze GCP API Gateway Error Rates
Queries Cloud Monitoring for gateway request error rates over the lookback window, flagging a 5xx ratio above `ERROR_RATE_THRESHOLD` (backend failing) and a tighter 401/403 ratio above `AUTH_ERROR_RATE_THRESHOLD` (JWT issuer / jwks_uri misconfiguration or API key enforcement). The 5xx query uses the gateway-scoped `proxy/*` metric; the 401/403 query needs `serviceruntime` and so is restricted to the project's managed services, skipping if none can be resolved.

### Analyze GCP API Gateway Latency
Queries Cloud Monitoring for p95 gateway latency, flagging values above `LATENCY_THRESHOLD_MS` degrades and checking the gateway-vs-backend latency gap (above `LATENCY_GAP_THRESHOLD_MS`) to isolate ESPv2 overhead from a merely slow backend. Both queries are scoped to the project's managed services — see [Metric type resolution and scoping](#metric-type-resolution-and-scoping) — and the check skips rather than reporting an unscoped, project-wide figure.

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

The `gcloud`, `jq`, `yq`, `curl`, `bc`, and `base64` CLI tools are required at runtime. `yq` and `base64` are needed to read OpenAPI specs: an `ApiConfig` returns its spec as base64-encoded YAML under `openapiDocuments[].document.contents`, so the invoker and backend checks decode it and normalise it to JSON before extracting `x-google-backend` addresses.

The `apigateway.googleapis.com`, `monitoring.googleapis.com`, `run.googleapis.com`, and `serviceusage.googleapis.com` APIs must be enabled for the project.

### Metric type resolution and scoping

API Gateway surfaces telemetry through two paths, and the difference matters for correctness, not just coverage:

- **`apigateway.googleapis.com/proxy/*`** is emitted by the `Gateway` resource, so it is inherently scoped to API Gateway. The 5xx error-rate check uses it.
- **`serviceruntime.googleapis.com/api/*`** is generic Service Infrastructure telemetry covering **every Google API call in the project** — Compute, GKE, Cloud Run and any admin tooling all land in it. The latency checks and the 401/403 rejection check need this path, because it is the only one carrying per-response-code and latency data.

Any `serviceruntime` query is therefore restricted to the managed services backing this project's APIs, via `resource.label."service"`. Without that restriction a p95 reflects unrelated project-wide API traffic rather than gateway traffic (in one test project, 63 seconds against gateways serving no traffic at all), and the 401/403 denominator becomes all project API calls, diluting the ratio enough to hide a real gateway auth problem.

**If no managed service can be resolved, these checks skip and say so rather than running unscoped.** A project-wide number reported as gateway latency is worse than no number.

`METRIC_TYPE_OVERRIDE` (and the latency equivalents) let you substitute a metric type if a project surfaces data on a different path. Note the defaults are used as-is; no metric-descriptor discovery is performed, so a mistyped override yields an empty series rather than an error.

## Interpreting results

**A failed task means "could not determine", not "healthy".** Every check writes a JSON issues file; if a check cannot run — missing inventory, unresolvable identity, unreadable spec — it fails loudly instead of writing an empty file. An empty issues file therefore means *checked and clean*, never *did not run*. The SLI likewise refuses to score a dimension whose check failed, and the aggregate task names the missing dimensions rather than scoring from a partial set.

This matters because the failure modes this bundle looks for are all silent by nature: a gateway missing `run.invoker` 403s every request while the gateway and Cloud Run both report `ACTIVE`. A check that degraded to "no issues found" on error would report exactly the same thing as a healthy gateway.

The same rule is applied to the GCP calls themselves: **"the API said no" and "I could not ask" are never collapsed into one value.** A failed `get-iam-policy`, a failed `api-configs describe`, or an unobtainable access token aborts the check rather than being substituted with an empty document. Left unhandled, a single dropped call reports a *confident wrong answer in both directions at once* — a healthy gateway flagged as missing its invoker binding, while the genuinely broken one is skipped and never reported.

A transient control-plane failure is a normal operating condition, not an exotic one, so expect these checks to fail occasionally. **A failing task means re-run it — not that the gateway is unhealthy.** Distinguishing the two is the whole point.

Because the runner reuses its working directory between runs, each task also deletes its own output before running and fails on a non-zero exit *before* anything reads that output. Without both, a check that failed would be reported using the **previous** run's file — and a stale *clean* result is the dangerous direction: it hides the exact condition this bundle exists to detect while reporting every task passed, and it goes staler the longer the check has been failing. This matters most for the SLI, which runs on a schedule and would otherwise serve the last good sub-score indefinitely.

### If the API Gateway API is not enabled

Discovery fails with an explicit message naming the API and the command to enable it, rather than reporting an empty project:

```
ERROR: the API Gateway API is not enabled on project 'my-project'.
       Enable it, then re-run:
       gcloud services enable apigateway.googleapis.com --project=my-project
```

This is deliberate. A project without the API enabled lists no resources, which is indistinguishable from a project that genuinely has no gateways — so every check would report zero issues and the SLI would score a perfect 1.0 for a project that was never actually inspected.

Interactive prompts are disabled (`CLOUDSDK_CORE_DISABLE_PROMPTS=1`) for the same reason: with a terminal attached, gcloud offers to enable a disabled API and blocks on stdin until the task times out, surfacing as `TimeoutExpired` instead of the reason gcloud already knows.

## Testing

`.test/offline/` runs every check against stubbed `gcloud` and `curl` responses and asserts each one *reports* the defect it exists to catch, then asserts a healthy project reports nothing. It needs only `bash`, `jq` and `yq` — no GCP project, no network:

```bash
cd .test && task test-offline-checks     # or: ./offline/run_offline_checks.sh
```

`.test/terraform/` provisions live fixtures for discovery and template rendering. See `.test/README.md` for the full requirement tiers.
