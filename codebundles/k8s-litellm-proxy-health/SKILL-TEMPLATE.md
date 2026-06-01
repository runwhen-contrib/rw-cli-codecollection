---
name: k8s-litellm-proxy-health
kind: skill-template
description: Exposes LiteLLM proxy health via HTTP APIs (liveness, readiness, models, optional deep checks, integrations) plus... Use when triaging or monitoring Kubernetes, AKS, EKS workloads with skill templa...
runtime:
  runbook: runbook.robot
  monitor: sli.robot
  executor: worker
  entrypoint: /home/runwhen/robot-runtime/runrobot.sh
  base_image: rw-base-runtime
platforms: [Kubernetes, AKS, EKS, GKE, OpenShift, LiteLLM, HTTP]
resource_types: [kubernetes_resource]
access: read-only
---

# Kubernetes LiteLLM Proxy API Health

## Summary

This CodeBundle calls the LiteLLM proxy HTTP API to report health beyond pod logs: liveness and readiness endpoints, configured models, optional expensive upstream health checks, integration health, and optional kubectl correlation with the Kubernetes Service.

See [README.md](README.md) for additional context.

## Tools

### Check LiteLLM Liveness Endpoint for Proxy `${LITELLM_SERVICE_NAME}`

Calls GET /health/liveliness (or /health/live) to confirm the proxy responds without invoking upstream LLM APIs.

- **Robot task name**: <code>Check LiteLLM Liveness Endpoint for Proxy `${LITELLM_SERVICE_NAME}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `check-litellm-liveness.sh`
- **Tags**: `Kubernetes`, `LiteLLM`, `liveness`, `access:read-only`, `data:metrics`
- **Reads**: —
- **Writes**: `litellm_liveness_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Check LiteLLM Readiness and Dependencies for Proxy `${LITELLM_SERVICE_NAME}`

Calls GET /health/readiness to surface database and cache connectivity and proxy version.

- **Robot task name**: <code>Check LiteLLM Readiness and Dependencies for Proxy `${LITELLM_SERVICE_NAME}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `check-litellm-readiness.sh`
- **Tags**: `Kubernetes`, `LiteLLM`, `readiness`, `access:read-only`, `data:metrics`
- **Reads**: —
- **Writes**: `litellm_readiness_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### List Configured Models and Routes for LiteLLM Proxy `${LITELLM_SERVICE_NAME}`

Uses /v1/models and /v1/model/info to verify expected models are registered.

- **Robot task name**: <code>List Configured Models and Routes for LiteLLM Proxy `${LITELLM_SERVICE_NAME}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `list-litellm-models.sh`
- **Tags**: `Kubernetes`, `LiteLLM`, `models`, `access:read-only`, `data:logs-config`
- **Reads**: —
- **Writes**: `litellm_models_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Check Optional Deep Model Health for LiteLLM Proxy `${LITELLM_SERVICE_NAME}`

When LITELLM_RUN_DEEP_HEALTH is true, calls GET /health with the master key to run upstream health checks (may incur provider cost).

- **Robot task name**: <code>Check Optional Deep Model Health for LiteLLM Proxy `${LITELLM_SERVICE_NAME}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `check-litellm-deep-health.sh`
- **Tags**: `Kubernetes`, `LiteLLM`, `deep-health`, `access:read-only`, `data:metrics`
- **Reads**: —
- **Writes**: `litellm_deep_health_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Check External Integration Service Health for LiteLLM Proxy `${LITELLM_SERVICE_NAME}`

Calls GET /health/services for configured integration names when LITELLM_INTEGRATION_SERVICES is set.

- **Robot task name**: <code>Check External Integration Service Health for LiteLLM Proxy `${LITELLM_SERVICE_NAME}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `check-litellm-integration-health.sh`
- **Tags**: `Kubernetes`, `LiteLLM`, `integrations`, `access:read-only`, `data:metrics`
- **Reads**: —
- **Writes**: `litellm_integration_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Verify Kubernetes Service Reachability Context for `${LITELLM_SERVICE_NAME}`

Uses kubectl to confirm the Service and Endpoints exist and align with LITELLM_HTTP_PORT for correlating API failures with cluster networking.

- **Robot task name**: <code>Verify Kubernetes Service Reachability Context for `${LITELLM_SERVICE_NAME}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `verify-litellm-k8s-service.sh`
- **Tags**: `Kubernetes`, `LiteLLM`, `service`, `access:read-only`, `data:metrics`
- **Reads**: —
- **Writes**: `litellm_k8s_service_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


## Monitor

Measures LiteLLM proxy availability using liveness and readiness HTTP endpoints and a lightweight Kubernetes Service existence check. Produces a value between 0 (failing) and 1 (healthy).

- **Robot file**: `sli.robot`
- **Score range**: `0.0` (failing) to `1.0` (healthy)
- **Aggregation**: arithmetic mean of the sub-checks below
- **Recommended interval**: `180s`

### Sub-checks

#### Collect LiteLLM Proxy Sub-Scores for Service `${LITELLM_SERVICE_NAME}`

Fetches liveness, readiness, and Kubernetes Service scores as binary 0/1 values.

- **Robot task name**: <code>Collect LiteLLM Proxy Sub-Scores for Service `${LITELLM_SERVICE_NAME}`</code>
- **Sub-metric name**: `liveness`
- **Underlying script**: `sli-litellm-proxy-score.sh`
- **Tags**: `access:read-only`, `data:metrics`
- **Reads**: —


## Inputs

| Name | Type | Description | Default | Required |
|---|---|---|---|---|
| `CONTEXT` | string | Kubernetes context to use for kubectl-backed checks. | — | yes |
| `NAMESPACE` | string | Namespace where the LiteLLM proxy runs. | — | yes |
| `PROXY_BASE_URL` | string | Optional base URL for the LiteLLM HTTP API (for example http://my-litellm.my-ns.svc.cluster.local:4000). Leave empty to auto port-forward to the Service via kubectl. | `` | yes |
| `LITELLM_SERVICE_NAME` | string | Kubernetes Service name for the LiteLLM proxy. | — | yes |
| `LITELLM_HTTP_PORT` | string | Service port number for the proxy HTTP listener. | `4000` | no |
| `LITELLM_RUN_DEEP_HEALTH` | string | Set to true to enable expensive GET /health upstream probes. | `false` | no |
| `LITELLM_INTEGRATION_SERVICES` | string | Comma-separated integration names for /health/services checks, or empty to skip. | `` | yes |
| `LITELLM_MASTER_KEY_SECRET_NAME` | string | Optional Kubernetes Secret name in NAMESPACE to read the master key from when the litellm_master_key secret is not provided. Leave empty to infer from the Pod env or auto-discover. | `` | yes |
| `LITELLM_MASTER_KEY_SECRET_KEY` | string | Optional data key within LITELLM_MASTER_KEY_SECRET_NAME. Leave empty to try common keys (masterkey, master_key, MASTER_KEY, LITELLM_MASTER_KEY). | `` | yes |
| `LITELLM_MASTER_KEY_INFER_FROM_POD` | string | When true (default), inspect the LiteLLM Pod env vars (e.g. LITELLM_MASTER_KEY) and follow any secretKeyRef to derive the key. Set to false to skip. | `true` | no |
| `LITELLM_MASTER_KEY_EXEC_FALLBACK` | string | When true (default), fall back to `kubectl exec <pod> -- printenv LITELLM_MASTER_KEY` if Pod spec inspection cannot resolve the secretKeyRef (for example due to missing RBAC on the Secret, or env wired via envFrom.secretRef). Set to false to forbid exec. | `true` | no |
| `LITELLM_MASTER_KEY_SECRET_PATTERN` | string | Regex used to auto-discover a master key Secret by name as a last-resort fallback when Pod env inference does not find anything. | `litellm` | no |
| `KUBERNETES_DISTRIBUTION_BINARY` | string | Kubernetes CLI binary to use. | `kubectl` | no |

## Secrets

| Name | Description | Required |
|---|---|---|
| `litellm_master_key` | Optional LiteLLM master or admin API key for protected routes. When omitted the codebundle will try to derive it from a Kubernetes Secret in NAMESPACE. | yes |
| `kubeconfig` | The kubernetes kubeconfig yaml containing connection configuration. | yes |

## Outputs

- Monitor health score (`0.0`–`1.0`) pushed by `sli.robot`
- `litellm_liveness_issues.json`
- `litellm_readiness_issues.json`
- `litellm_models_issues.json`
- `litellm_deep_health_issues.json`
- `litellm_integration_issues.json`
- `litellm_k8s_service_issues.json`

## How to invoke

### Production (RunWhen runner / worker)

The platform **runner** schedules work on a location **worker**. The worker
image (`rw-base-runtime`) executes Robot via `runrobot.sh` with
`RW_PATH_TO_ROBOT` set to the bound path under `/home/runwhen/collection/`.

- **Runbook**: `codebundles/k8s-litellm-proxy-health/runbook.robot`
- **Monitor**: `codebundles/k8s-litellm-proxy-health/sli.robot`

### Local development (devcontainer only)

`ro` is a dev-time wrapper in `codecollection-devtools` — not the enterprise runtime.

```bash
cd codebundles/k8s-litellm-proxy-health
export CONTEXT=...
export NAMESPACE=...
export PROXY_BASE_URL=...
export LITELLM_SERVICE_NAME=...
export LITELLM_HTTP_PORT=...
ro runbook.robot
```

### Standalone scripts (no Robot)


Set the input variables above, then run the matching script:

```bash
cd codebundles/k8s-litellm-proxy-health
export CONTEXT=...
export NAMESPACE=...
export PROXY_BASE_URL=...
bash _master_key_helper.sh
bash _portforward_helper.sh
bash check-litellm-deep-health.sh
bash check-litellm-integration-health.sh
bash check-litellm-liveness.sh
bash check-litellm-readiness.sh
bash list-litellm-models.sh
bash resolve-litellm-master-key.sh
bash sli-litellm-proxy-score.sh
bash verify-litellm-k8s-service.sh
```

## Source files

- `runbook.robot` — orchestrates tools and raises issues
- `sli.robot` — monitor scoring (`sli.robot` runtime file)
- `_master_key_helper.sh` — Bash helper script `_master_key_helper.sh`.
- `_portforward_helper.sh` — Bash helper script `_portforward_helper.sh`.
- `check-litellm-deep-health.sh` — Bash helper script `check-litellm-deep-health.sh`.
- `check-litellm-integration-health.sh` — Bash helper script `check-litellm-integration-health.sh`.
- `check-litellm-liveness.sh` — Bash helper script `check-litellm-liveness.sh`.
- `check-litellm-readiness.sh` — Bash helper script `check-litellm-readiness.sh`.
- `list-litellm-models.sh` — Bash helper script `list-litellm-models.sh`.
- `resolve-litellm-master-key.sh` — Bash helper script `resolve-litellm-master-key.sh`.
- `sli-litellm-proxy-score.sh` — Bash helper script `sli-litellm-proxy-score.sh`.
- `verify-litellm-k8s-service.sh` — Bash helper script `verify-litellm-k8s-service.sh`.
