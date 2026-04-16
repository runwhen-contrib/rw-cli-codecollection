# Kubernetes LiteLLM Proxy API Health

This CodeBundle calls the LiteLLM proxy HTTP API to report health beyond pod logs: liveness and readiness endpoints, configured models, optional expensive upstream health checks, integration health, and optional kubectl correlation with the Kubernetes Service.

## Overview

- **Liveness**: `GET /health/liveliness` (with `/health/live` fallback) for a lightweight process check that does not call upstream LLMs.
- **Readiness**: `GET /health/readiness` for database/cache connectivity and proxy metadata.
- **Models**: `GET /v1/models` and `GET /v1/model/info` to confirm models are registered (Bearer may be required).
- **Deep health** (optional): `GET /health` with the master key performs real upstream LLM calls; gated by `LITELLM_RUN_DEEP_HEALTH`.
- **Integrations** (optional): `GET /health/services` for named integrations when `LITELLM_INTEGRATION_SERVICES` is set.
- **Kubernetes**: `kubectl` checks for Service and Endpoints to correlate API failures with missing endpoints or port mismatches.
- **SLI**: `sli.robot` averages liveness, readiness, and Service presence into a 0–1 score.

Official API reference: [LiteLLM proxy health](https://docs.litellm.ai/docs/proxy/health).

## Configuration

### Required variables

- `CONTEXT`: Kubernetes context for kubectl-backed tasks.
- `NAMESPACE`: Namespace where the LiteLLM proxy runs.
- `PROXY_BASE_URL`: Base URL for the LiteLLM HTTP API. Use in-cluster DNS (for example `http://my-litellm.my-ns.svc.cluster.local:4000`) or `http://127.0.0.1:4000` when using `kubectl port-forward` from your workstation.
- `LITELLM_SERVICE_NAME`: Kubernetes `Service` name for the LiteLLM proxy (used for discovery and kubectl helpers).

### Optional variables

- `LITELLM_HTTP_PORT`: Expected Service port for HTTP (default: `4000`). Used when correlating `kubectl` output with `PROXY_BASE_URL`.
- `LITELLM_RUN_DEEP_HEALTH`: Set to `true` to enable `GET /health` upstream probes (can incur provider cost and latency).
- `LITELLM_INTEGRATION_SERVICES`: Comma-separated names passed to `/health/services` (empty skips this task).
- `KUBERNETES_DISTRIBUTION_BINARY`: `kubectl` or `oc` (default: `kubectl`).

### Secrets

- `kubeconfig`: Standard kubeconfig for optional kubectl tasks.
- `litellm_master_key`: LiteLLM master or admin API key (`Authorization: Bearer`) for protected routes such as `/health`, `/health/services`, and some model info routes. Optional for tasks that only hit unauthenticated endpoints.

### Port forward

For ClusterIP-only Services, run port-forward from a machine that has cluster access, for example:

`kubectl port-forward -n NAMESPACE svc/LITELLM_SERVICE_NAME 4000:4000`

Then set `PROXY_BASE_URL` to `http://127.0.0.1:4000`.

## Tasks overview

### Check LiteLLM Liveness Endpoint

Verifies the proxy responds on the liveness route without invoking upstream LLMs.

### Check LiteLLM Readiness and Dependencies

Parses `/health/readiness` for DB/cache status and raises issues when the database is not connected or cache errors appear.

### List Configured Models and Routes

Uses OpenAI-compatible and LiteLLM model info endpoints; flags empty model lists or authentication problems.

### Check Optional Deep Model Health

When enabled, calls `/health` with the master key. **This performs real LLM API calls**; keep disabled unless you intend to spend quota.

### Check External Integration Service Health

When integration names are configured, queries `/health/services` for each name.

### Verify Kubernetes Service Reachability Context

Uses kubectl to confirm the Service exists, ports align with `LITELLM_HTTP_PORT`, and Endpoints are present.
