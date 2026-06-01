---
name: k8s-otelcollector
kind: skill-template
description: This taskset performs diagnostic checks on a OpenTelemetry Collector to ensure it's pushing metrics. Use when triaging or monitoring GKE, EKS, AKS workloads with skill template `k8s-otelcollector`.
runtime:
  runbook: runbook.robot
  executor: worker
  entrypoint: /home/runwhen/robot-runtime/runrobot.sh
  base_image: rw-base-runtime
platforms: [GKE, EKS, AKS, Kubernetes, OpenTelemetry, otel, collector]
resource_types: [kubernetes_resource]
access: read-only
---

# K8s OpenTelemetry Collector Health

## Summary

Checks the OTEL collector's logs and metrics to determine its health, such as large queues or errors.

See [README.md](README.md) for additional context.

## Tools

### Query Collector Queued Spans in Namespace `${NAMESPACE}`

Query the collector metrics endpoint and inspect queue size

- **Robot task name**: <code>Query Collector Queued Spans in Namespace `${NAMESPACE}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `otel_metrics_check.sh`
- **Tags**: `access:read-only`, `otel-collector`, `metrics`, `queued`, `back`, `pressure`, `data:config`
- **Reads**: `NAMESPACE`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Check OpenTelemetry Collector Logs For Errors In Namespace `${NAMESPACE}`

Fetch logs and check for errors

- **Robot task name**: <code>Check OpenTelemetry Collector Logs For Errors In Namespace `${NAMESPACE}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `otel_error_check.sh`
- **Tags**: `access:read-only`, `otel-collector`, `metrics`, `errors`, `logs`, `data:logs-regexp`
- **Reads**: `NAMESPACE`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Query OpenTelemetry Logs For Dropped Spans In Namespace `${NAMESPACE}`

Query the collector logs for dropped spans from errors

- **Robot task name**: <code>Query OpenTelemetry Logs For Dropped Spans In Namespace `${NAMESPACE}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `otel_dropped_check.sh`
- **Tags**: `access:read-only`, `otel-collector`, `metrics`, `errors`, `logs`, `dropped`, `rejected`, `data:logs-regexp`
- **Reads**: `NAMESPACE`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


## Inputs

| Name | Type | Description | Default | Required |
|---|---|---|---|---|
| `NAMESPACE` | string | The name of the Kubernetes namespace to scope actions and searching to. | — | yes |
| `CONTEXT` | string | Which Kubernetes context to operate within. | — | yes |
| `KUBERNETES_DISTRIBUTION_BINARY` | string | Which binary to use for Kubernetes CLI commands. | `kubectl` | no |
| `WORKLOAD_SERVICE` | string | The service name used to curl the otel collector metrics endpoint. | `otel-demo-otelcol` | no |
| `WORKLOAD_NAME` | string | The workload name to act as a bastion-host. The collector can be used, or a bastion host depending on networking requirements. | `deployment/otel-demo-otelcol` | no |
| `METRICS_PORT` | string | The port used by the collector to serve its metrics at. This will be scraped. | `8888` | no |

## Secrets

_No secrets imported in Robot source._

## Outputs

_See Robot run output and platform report artifacts._

## How to invoke

### Production (RunWhen runner / worker)

The platform **runner** schedules work on a location **worker**. The worker
image (`rw-base-runtime`) executes Robot via `runrobot.sh` with
`RW_PATH_TO_ROBOT` set to the bound path under `/home/runwhen/collection/`.

- **Runbook**: `codebundles/k8s-otelcollector/runbook.robot`

### Local development (devcontainer only)

`ro` is a dev-time wrapper in `codecollection-devtools` — not the enterprise runtime.

```bash
cd codebundles/k8s-otelcollector
export NAMESPACE=...
export CONTEXT=...
export KUBERNETES_DISTRIBUTION_BINARY=...
export WORKLOAD_SERVICE=...
export WORKLOAD_NAME=...
export METRICS_PORT=...
ro runbook.robot
```

### Standalone scripts (no Robot)


Set the input variables above, then run the matching script:

```bash
cd codebundles/k8s-otelcollector
export NAMESPACE=...
export CONTEXT=...
export KUBERNETES_DISTRIBUTION_BINARY=...
export WORKLOAD_SERVICE=...
bash otel_dropped_check.sh
bash otel_error_check.sh
bash otel_metrics_check.sh
```

## Source files

- `runbook.robot` — orchestrates tools and raises issues
- `otel_dropped_check.sh` — Bash helper script `otel_dropped_check.sh`.
- `otel_error_check.sh` — Bash helper script `otel_error_check.sh`.
- `otel_metrics_check.sh` — Bash helper script `otel_metrics_check.sh`.
