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

- `CONTEXT`: Kubernetes context for `kubectl` correlation and cluster verification.
- `NAMESPACE`: Namespace where the LiteLLM `Service` runs.
- `PROXY_BASE_URL`: Reachable LiteLLM base URL (for example `http://litellm.default.svc.cluster.local:4000` or a port-forward URL).
- `LITELLM_SERVICE_NAME`: Kubernetes `Service` name used in titles and reports.

### Optional variables

- `RW_LOOKBACK_WINDOW`: Window for log/report date mapping (default: `24h`). Supports forms like `24h`, `7d`, `30m`.
- `LITELLM_SPEND_THRESHOLD_USD`: Alert when estimated global spend in the window exceeds this USD amount; `0` disables (default: `0`).
- `LITELLM_USER_IDS`: Comma-separated internal `user_id` values for `/user/info`; empty skips user checks.
- `LITELLM_TEAM_IDS`: Comma-separated team ids for `/team/info`; empty skips team checks.
- `KUBERNETES_DISTRIBUTION_BINARY`: `kubectl` or `oc` (default: `kubectl`).

### Secrets

- `litellm_master_key`: Bearer token with permission to call spend and admin routes (often the proxy master key or an admin key with spend scope).
- `kubeconfig`: Kubeconfig used only for optional cluster connectivity verification and standard RunWhen Kubernetes wiring.

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

## Notes

- Some routes are Enterprise-only or require specific key permissions; scripts emit clear issues on HTTP 403.
- Database-backed spend logs must be enabled on the proxy for full `/spend/logs` results.
- Set `custom.litellm_proxy_base_url` in workspace configuration when using discovery templates, or override `PROXY_BASE_URL` per SLX.
