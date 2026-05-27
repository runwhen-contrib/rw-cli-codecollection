---
name: k8s-litellm-spend-governance
description: Surfaces LiteLLM spend, budget, and failure signals from proxy Admin APIs for operational and cost governance. Use when triaging or monitoring Kubernetes, LiteLLM, spend workloads with skill templa...
runtime:
  runbook: runbook.robot
  monitor: sli.robot
  runner: ro
platforms: [Kubernetes, LiteLLM, spend, governance, metrics]
resource_types: [kubernetes_resource]
access: read-only
---

# Kubernetes LiteLLM Spend and Governance

## Summary

This CodeBundle queries the LiteLLM proxy Admin and spend APIs (not container logs alone) to surface cost pressure, budget blocks, rate limits, and provider-side failures.

See [README.md](README.md) for additional context.

## Tools

### Check Spend Tracking Configuration for LiteLLM `${LITELLM_SERVICE_NAME}` in `${NAMESPACE}`

Hits /health/readiness and /key/list to report whether a spend-tracking DB is wired up (so later tasks can distinguish "no DB" from "transient failure") and whether admin auth is working.

- **Robot task name**: <code>Check Spend Tracking Configuration for LiteLLM `${LITELLM_SERVICE_NAME}` in `${NAMESPACE}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `check-litellm-spend-config.sh`
- **Tags**: `Kubernetes`, `LiteLLM`, `access:read-only`, `data:metrics`
- **Reads**: —
- **Writes**: `spend_config_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Review Recent Spend Logs for Failures for LiteLLM `${LITELLM_SERVICE_NAME}` in `${NAMESPACE}`

Queries /spend/logs for the lookback window and flags rows matching budget, rate-limit, or provider failure heuristics.

- **Robot task name**: <code>Review Recent Spend Logs for Failures for LiteLLM `${LITELLM_SERVICE_NAME}` in `${NAMESPACE}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `review-litellm-spend-logs.sh`
- **Tags**: `Kubernetes`, `LiteLLM`, `access:read-only`, `data:metrics`
- **Reads**: —
- **Writes**: `spend_logs_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Check Global Spend Report Against Threshold for LiteLLM `${LITELLM_SERVICE_NAME}` in `${NAMESPACE}`

Calls /global/spend/report for the computed date window and compares estimated spend to LITELLM_SPEND_THRESHOLD_USD when non-zero.

- **Robot task name**: <code>Check Global Spend Report Against Threshold for LiteLLM `${LITELLM_SERVICE_NAME}` in `${NAMESPACE}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `check-litellm-global-spend.sh`
- **Tags**: `Kubernetes`, `LiteLLM`, `access:read-only`, `data:metrics`
- **Reads**: —
- **Writes**: `global_spend_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Inspect Virtual Key Spend and Remaining Budget for LiteLLM `${LITELLM_SERVICE_NAME}` in `${NAMESPACE}`

Uses /key/list when available to highlight keys near max_budget or with expired credentials.

- **Robot task name**: <code>Inspect Virtual Key Spend and Remaining Budget for LiteLLM `${LITELLM_SERVICE_NAME}` in `${NAMESPACE}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `inspect-litellm-key-budgets.sh`
- **Tags**: `Kubernetes`, `LiteLLM`, `access:read-only`, `data:metrics`
- **Reads**: —
- **Writes**: `key_budget_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Review User Budget and Rate Limit Status for LiteLLM `${LITELLM_SERVICE_NAME}` in `${NAMESPACE}`

Calls /user/info for configured user_ids to surface soft_budget_cooldown and spend versus limits.

- **Robot task name**: <code>Review User Budget and Rate Limit Status for LiteLLM `${LITELLM_SERVICE_NAME}` in `${NAMESPACE}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `review-litellm-user-budgets.sh`
- **Tags**: `Kubernetes`, `LiteLLM`, `access:read-only`, `data:metrics`
- **Reads**: —
- **Writes**: `user_budget_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Summarize Team Budgets and Limits for LiteLLM `${LITELLM_SERVICE_NAME}` in `${NAMESPACE}`

Queries /team/info for configured team identifiers to detect teams near max_budget or blocked traffic risk.

- **Robot task name**: <code>Summarize Team Budgets and Limits for LiteLLM `${LITELLM_SERVICE_NAME}` in `${NAMESPACE}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `summarize-litellm-team-budgets.sh`
- **Tags**: `Kubernetes`, `LiteLLM`, `access:read-only`, `data:metrics`
- **Reads**: —
- **Writes**: `team_budget_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Summarize Spend by Model and User for LiteLLM `${LITELLM_SERVICE_NAME}` in `${NAMESPACE}`

Aggregates per-model and per-user spend from /spend/logs?summarize=true (OSS-compatible, compact payload) and flags groups that exceed configured LITELLM_MODEL_SPEND_THRESHOLD_USD or LITELLM_USER_SPEND_THRESHOLD_USD.

- **Robot task name**: <code>Summarize Spend by Model and User for LiteLLM `${LITELLM_SERVICE_NAME}` in `${NAMESPACE}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `summarize-litellm-model-spend.sh`
- **Tags**: `Kubernetes`, `LiteLLM`, `access:read-only`, `data:metrics`
- **Reads**: —
- **Writes**: `model_spend_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Aggregate Error and Blocked Request Signals for LiteLLM `${LITELLM_SERVICE_NAME}` in `${NAMESPACE}`

Derives triage counts for budget_exceeded, rate limits, HTTP 429, and 5xx signals from spend logs in one summary.

- **Robot task name**: <code>Aggregate Error and Blocked Request Signals for LiteLLM `${LITELLM_SERVICE_NAME}` in `${NAMESPACE}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `aggregate-litellm-failure-signals.sh`
- **Tags**: `Kubernetes`, `LiteLLM`, `access:read-only`, `data:metrics`
- **Reads**: —
- **Writes**: `aggregate_failure_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


## Monitor

Measures LiteLLM proxy governance health from Admin API reachability, global spend versus threshold, and spend-log failure heuristics. Produces a value between 0 (failing) and 1 (healthy).

- **Robot file**: `sli.robot`
- **Score range**: `0.0` (failing) to `1.0` (healthy)
- **Aggregation**: arithmetic mean of the sub-checks below
- **Recommended interval**: `180s`

### Sub-checks

#### Score LiteLLM Proxy Reachability for `${LITELLM_SERVICE_NAME}`

Binary 1 if /health or / returns HTTP 2xx within timeout.

- **Robot task name**: <code>Score LiteLLM Proxy Reachability for `${LITELLM_SERVICE_NAME}`</code>
- **Sub-metric name**: `api_reachable`
- **Underlying script**: `sli-litellm-dimension.sh`
- **Tags**: `access:read-only`, `data:metrics`
- **Reads**: —


#### Score Global Spend Threshold for `${LITELLM_SERVICE_NAME}`

Binary 1 if threshold is disabled, spend is under threshold, or the report cannot be fetched.

- **Robot task name**: <code>Score Global Spend Threshold for `${LITELLM_SERVICE_NAME}`</code>
- **Sub-metric name**: `global_spend_threshold`
- **Underlying script**: `sli-litellm-dimension.sh`
- **Tags**: `access:read-only`, `data:metrics`
- **Reads**: —


#### Score Spend Logs Cleanliness for `${LITELLM_SERVICE_NAME}`

Binary 1 when the /spend/logs summary endpoint parses cleanly or is unavailable on OSS (neutral pass). Uses summarize=true so a >100 MB raw log response on a busy proxy cannot drop the request.

- **Robot task name**: <code>Score Spend Logs Cleanliness for `${LITELLM_SERVICE_NAME}`</code>
- **Sub-metric name**: `spend_logs_clean`
- **Underlying script**: `sli-litellm-dimension.sh`
- **Tags**: `access:read-only`, `data:metrics`
- **Reads**: —


#### Score Spend Tracking Readiness for `${LITELLM_SERVICE_NAME}`

Binary 1 when /health/readiness reports db=connected, so spend-governance tasks have a DB to query. This is the authoritative "is spend tracking configured" signal.

- **Robot task name**: <code>Score Spend Tracking Readiness for `${LITELLM_SERVICE_NAME}`</code>
- **Sub-metric name**: `spend_db_connected`
- **Underlying script**: `sli-litellm-dimension.sh`
- **Tags**: `access:read-only`, `data:metrics`
- **Reads**: —


#### Score Exception Rate for `${LITELLM_SERVICE_NAME}`

Binary 1 when exception_rate across top model deployments stays under LITELLM_EXCEPTION_RATE_PCT. Uses OSS /global/activity endpoints (compact payloads).

- **Robot task name**: <code>Score Exception Rate for `${LITELLM_SERVICE_NAME}`</code>
- **Sub-metric name**: `exception_rate_ok`
- **Underlying script**: `sli-litellm-dimension.sh`
- **Tags**: `access:read-only`, `data:metrics`
- **Reads**: —


## Inputs

| Name | Type | Description | Default | Required |
|---|---|---|---|---|
| `CONTEXT` | string | Kubernetes context name. | — | yes |
| `NAMESPACE` | string | Namespace where the LiteLLM service runs. | — | yes |
| `PROXY_BASE_URL` | string | Optional LiteLLM proxy base URL (for example http://my-litellm.my-ns.svc.cluster.local:4000). Leave empty to auto port-forward to the Service via kubectl. | `` | yes |
| `LITELLM_SERVICE_NAME` | string | Kubernetes Service name for labeling and reports. | — | yes |
| `LITELLM_HTTP_PORT` | string | Service port number for the proxy HTTP listener (used when auto port-forwarding). | `4000` | no |
| `LITELLM_SPEND_THRESHOLD_USD` | string | Alert when global estimated spend exceeds this USD amount (0 disables). | `0` | no |
| `LITELLM_MODEL_SPEND_THRESHOLD_USD` | string | Per-model spend threshold used by the Summarize Spend by Model task. 0 disables the issue but the report still lists top models by spend. | `0` | no |
| `LITELLM_USER_SPEND_THRESHOLD_USD` | string | Per-user spend threshold used by the Summarize Spend by Model task. 0 disables the issue but the report still lists top users by spend. | `0` | no |
| `LITELLM_EXCEPTION_RATE_PCT` | string | Percent of requests in the lookback window that may fail before the aggregate failure task raises an issue. Default 1 = 1%. | `1` | no |
| `LITELLM_ENABLE_RAW_LOG_SCAN` | string | Opt-in flag to additionally scan the raw /spend/logs response for failure keyword heuristics. Disabled by default because the response can exceed 100 MB on busy proxies and drop through a kubectl port-forward tunnel. Set to true only when querying a proxy with modest traffic or from inside the cluster. | `false` | no |
| `LITELLM_USER_IDS` | string | Comma-separated internal user_ids for /user/info (empty skips). | `${EMPTY}` | no |
| `LITELLM_TEAM_IDS` | string | Comma-separated team ids for /team/info (empty skips). | `${EMPTY}` | no |
| `LITELLM_MASTER_KEY_SECRET_NAME` | string | Optional Kubernetes Secret name in NAMESPACE to read the master key from when the litellm_master_key secret is not provided. Leave empty to infer from the Pod env or auto-discover. | `` | yes |
| `LITELLM_MASTER_KEY_SECRET_KEY` | string | Optional data key within LITELLM_MASTER_KEY_SECRET_NAME. Leave empty to try common keys (masterkey, master_key, MASTER_KEY, LITELLM_MASTER_KEY). | `` | yes |
| `LITELLM_MASTER_KEY_INFER_FROM_POD` | string | When true (default), inspect the LiteLLM Pod env vars (e.g. LITELLM_MASTER_KEY) and follow any secretKeyRef to derive the key. Set to false to skip. | `true` | no |
| `LITELLM_MASTER_KEY_EXEC_FALLBACK` | string | When true (default), fall back to `kubectl exec <pod> -- printenv LITELLM_MASTER_KEY` if Pod spec inspection cannot resolve the secretKeyRef. Set to false to forbid exec. | `true` | no |
| `LITELLM_MASTER_KEY_SECRET_PATTERN` | string | Regex used to auto-discover a master key Secret by name as a last-resort fallback when Pod env inference does not find anything. | `litellm` | no |
| `KUBERNETES_DISTRIBUTION_BINARY` | string | Kubernetes CLI binary for connectivity verification. | `kubectl` | no |

## Secrets

| Name | Description | Required |
|---|---|---|
| `kubeconfig` | Kubeconfig for kubectl connectivity checks. | yes |
| `litellm_master_key` | Optional LiteLLM master or admin API key for spend/governance routes. When omitted the codebundle will try to derive it from a Kubernetes Secret in NAMESPACE. | yes |

## Outputs

- Monitor health score (`0.0`–`1.0`) pushed by `sli.robot`
- `spend_config_issues.json`
- `spend_logs_issues.json`
- `global_spend_issues.json`
- `key_budget_issues.json`
- `user_budget_issues.json`
- `team_budget_issues.json`
- `model_spend_issues.json`
- `aggregate_failure_issues.json`

## How to invoke

### Preferred: Robot Framework runner (`ro`)

```bash
cd codebundles/k8s-litellm-spend-governance
export CONTEXT=...
export NAMESPACE=...
export PROXY_BASE_URL=...
export LITELLM_SERVICE_NAME=...
ro runbook.robot
```

### Standalone scripts (no Robot)


Set the input variables above, then run the matching script:

```bash
cd codebundles/k8s-litellm-spend-governance
export CONTEXT=...
export NAMESPACE=...
bash _master_key_helper.sh
bash _portforward_helper.sh
bash aggregate-litellm-failure-signals.sh
bash check-litellm-global-spend.sh
bash check-litellm-spend-config.sh
bash inspect-litellm-key-budgets.sh
bash litellm-http-helpers.sh
bash resolve-litellm-master-key.sh
bash review-litellm-spend-logs.sh
bash review-litellm-user-budgets.sh
bash sli-litellm-dimension.sh
bash summarize-litellm-model-spend.sh
# ... and 1 more scripts
```

## Source files

- `runbook.robot` — orchestrates tools and raises issues
- `sli.robot` — monitor scoring (`sli.robot` runtime file)
- `_master_key_helper.sh` — Bash helper script `_master_key_helper.sh`.
- `_portforward_helper.sh` — Bash helper script `_portforward_helper.sh`.
- `aggregate-litellm-failure-signals.sh` — Bash helper script `aggregate-litellm-failure-signals.sh`.
- `check-litellm-global-spend.sh` — Bash helper script `check-litellm-global-spend.sh`.
- `check-litellm-spend-config.sh` — Bash helper script `check-litellm-spend-config.sh`.
- `inspect-litellm-key-budgets.sh` — Bash helper script `inspect-litellm-key-budgets.sh`.
- `litellm-http-helpers.sh` — Bash helper script `litellm-http-helpers.sh`.
- `resolve-litellm-master-key.sh` — Bash helper script `resolve-litellm-master-key.sh`.
- `review-litellm-spend-logs.sh` — Bash helper script `review-litellm-spend-logs.sh`.
- `review-litellm-user-budgets.sh` — Bash helper script `review-litellm-user-budgets.sh`.
- `sli-litellm-dimension.sh` — Bash helper script `sli-litellm-dimension.sh`.
- `summarize-litellm-model-spend.sh` — Bash helper script `summarize-litellm-model-spend.sh`.
- `summarize-litellm-team-budgets.sh` — Bash helper script `summarize-litellm-team-budgets.sh`.
