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
- `LITELLM_SERVICE_NAME`: Kubernetes `Service` name for the LiteLLM proxy (used for discovery, kubectl helpers, and automatic port-forward).

### Optional variables

- `PROXY_BASE_URL`: Base URL for the LiteLLM HTTP API (for example `http://my-litellm.my-ns.svc.cluster.local:4000`). **Leave empty to auto port-forward** to `svc/${LITELLM_SERVICE_NAME}` on `${LITELLM_HTTP_PORT}` via `kubectl` — this is the default and preferred mode when running from outside the cluster.
- `LITELLM_HTTP_PORT`: Service port for HTTP (default: `4000`). Used for the port-forward and for correlating `kubectl` output with `PROXY_BASE_URL` when one is supplied.
- `LITELLM_LOCAL_PORT`: Local port to bind when auto port-forwarding (default: a free ephemeral port).
- `LITELLM_PF_WAIT_SECS`: Max seconds to wait for the port-forward to become ready (default: `10`).
- `LITELLM_RUN_DEEP_HEALTH`: Set to `true` to enable `GET /health` upstream probes (can incur provider cost and latency).
- `LITELLM_INTEGRATION_SERVICES`: Comma-separated names passed to `/health/services` (empty skips this task).
- `LITELLM_MASTER_KEY_SECRET_NAME`: Optional Kubernetes Secret name in `NAMESPACE` to read the master key from when the `litellm_master_key` secret is not provided. Leave empty to infer from Pod env vars or auto-discover by name.
- `LITELLM_MASTER_KEY_SECRET_KEY`: Optional data key within `LITELLM_MASTER_KEY_SECRET_NAME`. Leave empty to try common keys (`masterkey`, `master_key`, `MASTER_KEY`, `LITELLM_MASTER_KEY`, `litellm_master_key`, `api_key`, `API_KEY`).
- `LITELLM_MASTER_KEY_INFER_FROM_POD`: When `true` (default), inspect the backing Pod's `containers[].env[]` (matching names like `LITELLM_MASTER_KEY`, `MASTER_KEY`, …) and, if it references `valueFrom.secretKeyRef`, resolve the Secret. Set to `false` to disable (also disables the exec fallback below).
- `LITELLM_MASTER_KEY_EXEC_FALLBACK`: When `true` (default), if Pod-spec inspection cannot resolve the Secret (missing `get secret` RBAC, or env wired via `envFrom.secretRef`), run `kubectl exec <pod> -- printenv <NAME>` to read the value at runtime. Set to `false` to forbid exec.
- `LITELLM_MASTER_KEY_SECRET_PATTERN`: Regex used to auto-discover a master key Secret by name as a last-resort fallback (default: `litellm`).
- `KUBERNETES_DISTRIBUTION_BINARY`: `kubectl` or `oc` (default: `kubectl`).

### Secrets

- `kubeconfig`: Standard kubeconfig for kubectl tasks and for the auto port-forward.
- `litellm_master_key` *(optional)*: LiteLLM master or admin API key (`Authorization: Bearer`) for protected routes such as `/health`, `/health/services`, and some model info routes. When not provided the codebundle will try to derive it from a Kubernetes Secret in `NAMESPACE` (see [Master key resolution](#master-key-resolution)).

### Master key resolution

The master key is resolved **once in Suite Setup** by `resolve-litellm-master-key.sh` and cached to `./.litellm_master_key` (mode 600) in the working directory. Every downstream task (`list-litellm-models`, deep health, integration health) reads the cache via the shared helper, so the resolution logic runs only once per runbook invocation and its output is surfaced in the report.

Resolution order (first hit wins):

0. A non-empty cache file at `./.litellm_master_key` (written by Suite Setup on a prior step).
1. `LITELLM_MASTER_KEY` already set in the environment.
2. The `litellm_master_key` RunWhen secret is provided (after trimming; mangled empty injections are ignored).
3. `LITELLM_MASTER_KEY_SECRET_NAME` is set → read that Secret from `NAMESPACE`, trying `LITELLM_MASTER_KEY_SECRET_KEY` if set, otherwise the default candidate keys.
4. **Pod env inference** (enabled by default) → look up the `Service` selector for `LITELLM_SERVICE_NAME`, pick a backing Pod, walk `containers[].env[]`, and for the first entry named like `LITELLM_MASTER_KEY` / `MASTER_KEY` / `PROXY_MASTER_KEY` / `LITELLM_PROXY_MASTER_KEY`:
   - if `.value` is set, use it as a literal;
   - if `.valueFrom.secretKeyRef` is set, read that Secret and key.
   Disable with `LITELLM_MASTER_KEY_INFER_FROM_POD=false`.
5. **Exec fallback** (enabled by default) → if step 4 cannot resolve the value (for example the runbook's ServiceAccount lacks `get secret` RBAC, or the env is injected via `envFrom.secretRef` which is not visible in the Pod spec), run `kubectl exec <pod> -- printenv <NAME>` for each candidate env name and use the first non-empty result. Disable with `LITELLM_MASTER_KEY_EXEC_FALLBACK=false`.
6. Auto-discovery by name → search Secrets in `NAMESPACE` whose name matches `LITELLM_MASTER_KEY_SECRET_PATTERN` (default: `litellm`), trying the default candidate keys.

If none match, tasks that need the key will emit an issue indicating the key could not be resolved. Tasks that only hit unauthenticated endpoints are unaffected.

### Connectivity modes

The scripts support two modes, selected automatically by whether `PROXY_BASE_URL` is set:

1. **Auto port-forward (default when `PROXY_BASE_URL` is empty)** — each script runs `kubectl port-forward svc/${LITELLM_SERVICE_NAME} <local_port>:${LITELLM_HTTP_PORT}` in the background, sets `PROXY_BASE_URL=http://127.0.0.1:<local_port>`, and tears the forward down on exit. Works for ClusterIP-only Services as long as the runner has kubeconfig access.
2. **Direct URL** — set `PROXY_BASE_URL` to an in-cluster DNS, ingress, or existing port-forward URL (for example `http://127.0.0.1:4000`). No port-forward is started.

## Auto-discovery

The generation rule in `.runwhen/generation-rules/k8s-litellm-proxy-health.yaml` matches a Kubernetes `Service` only when **both** conditions hold:

1. The Service name contains the substring `litellm`.
2. The Service exposes the LiteLLM default HTTP port (`4000`) on `spec.ports[*].port`.

The port check is the strongest discriminator — it filters out subchart Services (Redis=`6379`, PostgreSQL=`5432`, pgAdmin, pgBouncer, exporters, etc.) that share the `litellm-*` name prefix but expose unrelated ports. If you run the proxy on a non-default port, update the rule's port pattern or clone the rule and relax it.

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
