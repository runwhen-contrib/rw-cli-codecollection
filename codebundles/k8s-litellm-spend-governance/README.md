# Kubernetes LiteLLM Spend and Governance

This CodeBundle queries the LiteLLM proxy Admin and spend APIs (not container logs alone) to surface cost pressure, budget blocks, rate limits, and provider-side failures. Pair it with cluster connectivity (`kubectl`) for context and with port-forward or in-cluster URLs for `PROXY_BASE_URL`.

## Overview

- **Config check**: Hits `/health/readiness` and `/key/list` to confirm a spend-tracking DB is wired up and admin auth works. This runs first so the rest of the runbook can trust its signals.
- **Spend logs**: Scans the compact `/spend/logs?summarize=true` view for the lookback window; optionally also does a raw-log keyword scan (off by default).
- **Global spend**: Uses `/global/spend/report` when licensed, otherwise aggregates `.spend` across `/key/list` and compares to `LITELLM_SPEND_THRESHOLD_USD`.
- **Per-model / per-user spend**: Aggregates the `/spend/logs?summarize=true` rollup into top-N model and top-N user tables and flags groups that exceed per-model / per-user thresholds.
- **Keys**: When `/key/list` is available, flags keys near `max_budget` or past `expires`.
- **Users / teams**: Optional `/user/info` and `/team/info` checks for cooldowns and budget risk.
- **Aggregate failure signals**: Sums exceptions per model via `/global/activity/exceptions/deployment` (OSS-friendly) and raises an issue when the exception rate exceeds `LITELLM_EXCEPTION_RATE_PCT`.

The codebundle is **scope-complementary** with `k8s-litellm-proxy-health`:

| Concern                       | Bundle                            |
|-------------------------------|-----------------------------------|
| Liveness, readiness, `/health`| `k8s-litellm-proxy-health`        |
| Model listing (`/v1/models`)  | `k8s-litellm-proxy-health`        |
| Integration / deep-health     | `k8s-litellm-proxy-health`        |
| **Spend-DB readiness check**  | `k8s-litellm-spend-governance`    |
| **Top-model / top-user spend**| `k8s-litellm-spend-governance`    |
| **Exception rate per model**  | `k8s-litellm-spend-governance`    |
| Budgets / threshold alerts    | `k8s-litellm-spend-governance`    |

## Configuration

### Required variables

- `CONTEXT`: Kubernetes context for `kubectl` correlation, cluster verification, and the port-forward / master-key fallbacks.
- `NAMESPACE`: Namespace where the LiteLLM `Service` runs.
- `LITELLM_SERVICE_NAME`: Kubernetes `Service` name used in titles, reports, and port-forward targeting.

### Optional variables

- `PROXY_BASE_URL`: Reachable LiteLLM base URL (for example `http://litellm.default.svc.cluster.local:4000`). Leave empty to auto `kubectl port-forward` to `svc/${LITELLM_SERVICE_NAME}` on `LITELLM_HTTP_PORT`.
- `LITELLM_HTTP_PORT`: Service port for the proxy HTTP listener used by the port-forward fallback (default: `4000`).
- `RW_LOOKBACK_WINDOW`: Window for log/report date mapping (default: `24h`). Supports forms like `24h`, `7d`, `30m`.
- `LITELLM_SPEND_THRESHOLD_USD`: Alert when total estimated global spend in the window exceeds this USD amount; `0` disables (default: `0`).
- `LITELLM_MODEL_SPEND_THRESHOLD_USD`: Alert when any single model group exceeds this per-model USD amount in the window; `0` disables (default: `0`).
- `LITELLM_USER_SPEND_THRESHOLD_USD`: Alert when any single user exceeds this per-user USD amount in the window; `0` disables (default: `0`).
- `LITELLM_EXCEPTION_RATE_PCT`: Percent of requests allowed to fail before the aggregate failure task raises an issue (default: `1`).
- `LITELLM_ENABLE_RAW_LOG_SCAN`: Opt-in to scan the raw `/spend/logs?summarize=false` response for failure keywords. Off by default because the payload can exceed 100 MB and drop through `kubectl port-forward` tunnels (default: `false`).
- `LITELLM_USER_IDS`: Comma-separated internal `user_id` values for `/user/info`; empty skips user checks.
- `LITELLM_TEAM_IDS`: Comma-separated team ids for `/team/info`; empty skips team checks.
- `LITELLM_MASTER_KEY_SECRET_NAME`: Kubernetes Secret in `NAMESPACE` to read the master key from when the workspace `litellm_master_key` secret is not provided.
- `LITELLM_MASTER_KEY_SECRET_KEY`: Data key within that Secret. Empty means try common keys (`masterkey`, `master_key`, `MASTER_KEY`, `LITELLM_MASTER_KEY`, ...).
- `LITELLM_MASTER_KEY_INFER_FROM_POD` (default `true`): Inspect LiteLLM Pod env vars and follow any `secretKeyRef` to derive the key.
- `LITELLM_MASTER_KEY_EXEC_FALLBACK` (default `true`): Fall back to `kubectl exec <pod> -- printenv LITELLM_MASTER_KEY` when Pod spec inspection can't resolve the value (for example env wired via `envFrom.secretRef`).
- `LITELLM_MASTER_KEY_SECRET_PATTERN` (default `litellm`): Regex used for last-resort Secret name-pattern auto-discovery.
- `KUBERNETES_DISTRIBUTION_BINARY`: `kubectl` or `oc` (default: `kubectl`).

### Secrets

- `kubeconfig` (required): Kubeconfig used for cluster connectivity verification, port-forwarding, and master-key derivation (`get secret` / `exec`).
- `litellm_master_key` (optional): Bearer token with permission to call spend and admin routes. When omitted, the codebundle tries, in order:
  1. A Kubernetes Secret named `LITELLM_MASTER_KEY_SECRET_NAME` in `NAMESPACE` (with optional `LITELLM_MASTER_KEY_SECRET_KEY`).
  2. Pod env inference on the LiteLLM workload backing `LITELLM_SERVICE_NAME` (walks `containers[].env[]` and follows any `valueFrom.secretKeyRef`).
  3. `kubectl exec <pod> -- printenv LITELLM_MASTER_KEY` (or sibling names like `MASTER_KEY`) for the case where the env var is wired via `envFrom.secretRef` or the runner lacks `get secret` RBAC.
  4. Secret name-pattern search in `NAMESPACE` using `LITELLM_MASTER_KEY_SECRET_PATTERN`.

The resolved key is cached in `./.litellm_master_key` (mode 600) by Suite Setup so the per-task scripts don't re-run `kubectl` for every HTTP call. The key value is never printed — only the origin (Secret/Pod/env name) appears in task output.

## Tasks

### Check Spend Tracking Configuration *(runs first)*

Calls `/health/readiness` and reports `db`, `cache`, `litellm_version`, and `success_callbacks`. Also probes `/key/list?size=1` to confirm admin auth works. Emits:

- sev 3 if `/health/readiness` is unreachable or `db != "connected"` (spend tracking fundamentally unavailable).
- sev 3 if `/key/list` is unreachable (admin auth or routing broken).
- sev 2 if readiness `status` field is not `connected` / `healthy`.

Every other task calls the same readiness endpoint when a spend request fails so its message can distinguish "DB not configured" from "DB connected but response stalled".

### Review Recent Spend Logs for Failures

Pulls `/spend/logs?summarize=true` (compact: ~1-2 KB regardless of traffic volume) and reports per-user / per-model rollups. Optionally also scans the raw `summarize=false` response when `LITELLM_ENABLE_RAW_LOG_SCAN=true`.

### Check Global Spend Report Against Threshold

Calls `/global/spend/report` (LiteLLM Enterprise) first. On OSS the codebundle detects the `LITELLM_LICENSE` gate and falls back to summing `.spend` across `/key/list` entries.

### Summarize Spend by Model and User

Aggregates per-model and per-user spend from `/spend/logs?summarize=true`; always produces a top-N ranking in the report. Raises issues when a model or user exceeds `LITELLM_MODEL_SPEND_THRESHOLD_USD` or `LITELLM_USER_SPEND_THRESHOLD_USD` respectively. Also pulls `/global/activity/model` for per-model request / token volumes (OSS-compatible).

### Inspect Virtual Key Spend and Remaining Budget

Uses `/key/list` to find keys near `max_budget` or past `expires`.

### Review User Budget and Rate Limit Status

For each entry in `LITELLM_USER_IDS`, calls `/user/info` and surfaces `soft_budget_cooldown` when true.

### Summarize Team Budgets and Limits

For each entry in `LITELLM_TEAM_IDS`, calls `/team/info` and flags teams at or above 90% of `max_budget`.

### Aggregate Error and Blocked Request Signals

Enumerates top-N model groups via `/global/activity/model`, sums per-deployment exception counts via `/global/activity/exceptions/deployment`, and computes the exception rate vs. `/global/activity`'s total request count. Raises an issue when the rate exceeds `LITELLM_EXCEPTION_RATE_PCT` (severity is escalated when the rate is 5x the threshold). All three endpoints are OSS-compatible and return compact JSON.

## SLI

`sli.robot` publishes a 0–1 score averaged from five binary sub-dimensions:

| sub_name                  | 1 when                                                            |
|---------------------------|-------------------------------------------------------------------|
| `api_reachable`           | `/health/liveliness`, `/health`, or `/` returns 2xx               |
| `spend_db_connected`      | `/health/readiness` reports `db=connected`                        |
| `global_spend_threshold`  | threshold disabled OR spend under threshold OR source unavailable |
| `spend_logs_clean`        | summarize=true view returns valid JSON OR endpoint unavailable on OSS |
| `exception_rate_ok`       | computed exception rate ≤ `LITELLM_EXCEPTION_RATE_PCT`            |

## Auto-discovery

The generation rule in `.runwhen/generation-rules/k8s-litellm-spend-governance.yaml` matches a Kubernetes `Service` only when **both** conditions hold:

1. The Service name contains the substring `litellm`.
2. The Service exposes the LiteLLM default HTTP port (`4000`) on `spec.ports[*].port`.

The port check is the strongest discriminator — it filters out subchart Services (Redis=`6379`, PostgreSQL=`5432`, pgBouncer=`6432`, pgAdmin/exporters=`80`, etc.) that share the `litellm-*` name prefix but expose unrelated ports. If you run the proxy on a non-default port, update the rule's port pattern or clone the rule and relax it.

## OSS vs Enterprise endpoint behavior

LiteLLM ships the same Admin API for OSS and Enterprise, but a handful of routes are license-gated or DB-backed. The codebundle probes `/health/readiness` up front and degrades gracefully for both cases.

| Route                                           | OSS   | Enterprise | Payload size | Behavior when unavailable                                   |
|-------------------------------------------------|:-----:|:----------:|:-------------|:------------------------------------------------------------|
| `/health/readiness`                             | yes   | yes        | ~1 KB        | sev-3 issue (spend tracking can't be trusted)               |
| `/health/liveliness`                            | yes   | yes        | <100 B       | scored as unreachable                                       |
| `/key/list`, `/key/info`                        | yes   | yes        | small        | used for key-budget checks AND OSS spend aggregation        |
| `/user/info`                                    | yes   | yes        | small        | used when `LITELLM_USER_IDS` is set                         |
| `/team/info`                                    | yes   | yes        | small        | used when `LITELLM_TEAM_IDS` is set                         |
| `/spend/logs?summarize=true`                    | yes*  | yes        | 1-2 KB       | informational when DB not configured (`*DB-backed`)         |
| `/spend/logs?summarize=false`                   | yes*  | yes        | **can exceed 100 MB** | **disabled by default** — tunnel caps apply      |
| `/global/activity`                              | yes*  | yes        | small        | informational when DB not configured                        |
| `/global/activity/model`                        | yes*  | yes        | small        | informational when DB not configured                        |
| `/global/activity/exceptions/deployment`        | yes*  | yes        | small        | informational when DB not configured                        |
| `/global/spend/report`                          | no    | yes        | -            | auto-fallback: sum `.spend` across `/key/list`              |
| `/global/spend/models`, `/global/spend/tags`    | no    | yes        | -            | not used; Per-model task relies on OSS routes above         |

### Disambiguating "no DB" vs "tunnel drop"

Before this codebundle ships readiness-aware classification, spend endpoints that stalled (HTTP 000) were indistinguishable from a real absence of DB backing. The reality is that `/spend/logs?summarize=false` on a busy proxy can return **hundreds of megabytes** and reliably drop through a `kubectl port-forward` tunnel within a few seconds. The helper `litellm_classify_spend_failure` consults `/health/readiness` and returns one of:

- `db-not-connected` — informational (severity 1) issue, no DB to query.
- `transient-tunnel-or-timeout` — severity 2 issue recommending a narrower window or a direct in-cluster connection.
- `enterprise-gated` — silent skip on OSS.
- `endpoint-not-found` / `auth-or-license-denied` — specific error surfaced.

This is why the summary-first task design (`summarize=true` is 1-2 KB) is so much more reliable for ongoing governance: the same data, through a much smaller pipe.

## HTTP timeouts

Admin API calls use conservative per-request timeouts so a single stalled endpoint can never exceed the Robot 180s subprocess budget:

- `LITELLM_CONNECT_TIMEOUT` (default `5` seconds)
- `LITELLM_MAX_TIME` (default `20` seconds)
- `LITELLM_HTTP_RETRIES` (default `2`) — retries only on HTTP `000` (connection failure) with a 1s back-off, never on real 4xx/5xx responses.
- `LITELLM_RAW_MAX_TIME` (default `15` seconds) — tighter cap used by the opt-in raw log scan.

All four are overridable per environment if your proxy is slow or your port-forward is higher-throughput.

## Notes

- Database-backed spend logs must be enabled on the proxy for per-user / per-model aggregates to have data. Without them, the "Check Spend Tracking Configuration" task emits a sev-3 issue and subsequent tasks skip gracefully.
- Set `custom.litellm_proxy_base_url` in workspace configuration when using discovery templates, or override `PROXY_BASE_URL` per SLX. Leaving it empty triggers auto `kubectl port-forward`.
- For very high-traffic proxies, consider running the runbook from inside the cluster (e.g. via a sidecar or direct Service URL in `PROXY_BASE_URL`) so the port-forward payload cap stops applying to the optional raw scan.
