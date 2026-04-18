# Kubernetes LiteLLM Spend and Governance

This CodeBundle queries the LiteLLM proxy Admin and spend APIs (not container logs alone) to surface cost pressure, budget blocks, rate limits, and provider-side failures. Pair it with cluster connectivity (`kubectl`) for context and with port-forward or in-cluster URLs for `PROXY_BASE_URL`.

## Overview

- **Spend logs**: Scans `/spend/logs` for budget, rate-limit, and HTTP error heuristics in the lookback window.
- **Global spend**: Reads `/global/spend/report` and optionally compares estimated USD spend to `LITELLM_SPEND_THRESHOLD_USD`.
- **Keys**: When `/key/list` is available, flags keys near `max_budget` or past `expires`.
- **Users / teams**: Optional `/user/info` and `/team/info` checks for cooldowns and budget risk.
- **Aggregate triage**: Summarizes failure-mode counts from spend logs for quick review.

## Configuration

### Required variables

- `CONTEXT`: Kubernetes context for `kubectl` correlation, cluster verification, and the port-forward / master-key fallbacks.
- `NAMESPACE`: Namespace where the LiteLLM `Service` runs.
- `LITELLM_SERVICE_NAME`: Kubernetes `Service` name used in titles, reports, and port-forward targeting.

### Optional variables

- `PROXY_BASE_URL`: Reachable LiteLLM base URL (for example `http://litellm.default.svc.cluster.local:4000`). Leave empty to auto `kubectl port-forward` to `svc/${LITELLM_SERVICE_NAME}` on `LITELLM_HTTP_PORT`.
- `LITELLM_HTTP_PORT`: Service port for the proxy HTTP listener used by the port-forward fallback (default: `4000`).
- `RW_LOOKBACK_WINDOW`: Window for log/report date mapping (default: `24h`). Supports forms like `24h`, `7d`, `30m`.
- `LITELLM_SPEND_THRESHOLD_USD`: Alert when estimated global spend in the window exceeds this USD amount; `0` disables (default: `0`).
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

### Review Recent Spend Logs for Failures

Calls `/spend/logs` with `summarize=false` for the computed date window and raises issues when heuristics match budget blocks, rate limits, or provider/HTTP failures.

### Check Global Spend Report Against Threshold

Calls `/global/spend/report` and, when `LITELLM_SPEND_THRESHOLD_USD` is greater than zero, compares estimated spend to the threshold.

### Inspect Virtual Key Spend and Remaining Budget

Uses `/key/list` when available to find keys near `max_budget` or expired keys.

### Review User Budget and Rate Limit Status

For each entry in `LITELLM_USER_IDS`, calls `/user/info` and surfaces `soft_budget_cooldown` when true.

### Summarize Team Budgets and Limits

For each entry in `LITELLM_TEAM_IDS`, calls `/team/info` and flags teams at or above 90% of `max_budget`.

### Aggregate Error and Blocked Request Signals

Produces triage counts (for example `budget_exceeded`, rate-limit, 429, 5xx patterns) from spend logs and raises an issue when the combined signal volume is high.

## SLI

`sli.robot` publishes a 0–1 score from three dimensions: proxy reachability (`/health` or `/`), global spend versus threshold, and spend-log failure heuristics. Generation rules emit an SLI template alongside the runbook.

## Auto-discovery

The generation rule in `.runwhen/generation-rules/k8s-litellm-spend-governance.yaml` matches a Kubernetes `Service` only when **both** conditions hold:

1. The Service name contains the substring `litellm`.
2. The Service exposes the LiteLLM default HTTP port (`4000`) on `spec.ports[*].port`.

The port check is the strongest discriminator — it filters out subchart Services (Redis=`6379`, PostgreSQL=`5432`, pgBouncer=`6432`, pgAdmin/exporters=`80`, etc.) that share the `litellm-*` name prefix but expose unrelated ports. If you run the proxy on a non-default port, update the rule's port pattern or clone the rule and relax it.

## Notes

- Some routes are Enterprise-only or require specific key permissions; scripts emit clear issues on HTTP 403.
- Database-backed spend logs must be enabled on the proxy for full `/spend/logs` results.
- Set `custom.litellm_proxy_base_url` in workspace configuration when using discovery templates, or override `PROXY_BASE_URL` per SLX.
