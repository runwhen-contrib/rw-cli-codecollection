---
name: k8s-jaeger-http-query
kind: skill-template
description: This taskset queries Jaeger API directly for trace details and parses the results. Use when triaging or monitoring GKE, EKS, AKS workloads with skill template `k8s-jaeger-http-query`.
runtime:
  runbook: runbook.robot
  executor: worker
  entrypoint: /home/runwhen/robot-runtime/runrobot.sh
  base_image: rw-base-runtime
platforms: [GKE, EKS, AKS, Kubernetes, HTTP]
resource_types: [kubernetes_resource]
access: read-only
---

# K8s Jaeger Query

## Summary

This codebundle is used for searching in a Jaeger instance for trace data that indicates issues with services.

See [README.md](README.md) for additional context.

## Tools

### Query Traces in Jaeger for Unhealthy HTTP Response Codes in Namespace `${NAMESPACE}`

Query Jaeger for all services and report on any HTTP related trace errors

- **Robot task name**: <code>Query Traces in Jaeger for Unhealthy HTTP Response Codes in Namespace `${NAMESPACE}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `query_jaeger_http_errors.sh`
- **Tags**: `jaeger`, `http`, `ingress`, `latency`, `errors`, `traces`, `kubernetes`, `data:logs-regexp`
- **Reads**: `NAMESPACE`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


## Inputs

| Name | Type | Description | Default | Required |
|---|---|---|---|---|
| `NAMESPACE` | string | The name of the Kubernetes namespace to scope actions and searching to. | — | yes |
| `CONTEXT` | string | Which Kubernetes context to operate within. | — | yes |
| `SERVICE_EXCLUSIONS` | string | Comma separated list of serivces to exclude from the query | `none` | no |
| `LOOKBACK` | string | The age to query for traces. Defaults to 5m. | `5m` | no |
| `KUBERNETES_DISTRIBUTION_BINARY` | string | Which binary to use for Kubernetes CLI commands. | `kubectl` | no |

## Secrets

_No secrets imported in Robot source._

## Outputs

_See Robot run output and platform report artifacts._

## How to invoke

### Production (RunWhen runner / worker)

The platform **runner** schedules work on a location **worker**. The worker
image (`rw-base-runtime`) executes Robot via `runrobot.sh` with
`RW_PATH_TO_ROBOT` set to the bound path under `/home/runwhen/collection/`.

- **Runbook**: `codebundles/k8s-jaeger-http-query/runbook.robot`

### Local development (devcontainer only)

`ro` is a dev-time wrapper in `codecollection-devtools` — not the enterprise runtime.

```bash
cd codebundles/k8s-jaeger-http-query
export NAMESPACE=...
export CONTEXT=...
export SERVICE_EXCLUSIONS=...
export LOOKBACK=...
export KUBERNETES_DISTRIBUTION_BINARY=...
ro runbook.robot
```

### Standalone scripts (no Robot)


Set the input variables above, then run the matching script:

```bash
cd codebundles/k8s-jaeger-http-query
export NAMESPACE=...
export CONTEXT=...
export SERVICE_EXCLUSIONS=...
export LOOKBACK=...
bash query_jaeger_http_errors.sh
```

## Source files

- `runbook.robot` — orchestrates tools and raises issues
- `query_jaeger_http_errors.sh` — Bash helper script `query_jaeger_http_errors.sh`.
