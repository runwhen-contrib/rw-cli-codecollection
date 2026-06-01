---
name: k8s-tail-logs-dynamic
kind: skill-template
description: Performs application-level troubleshooting by inspecting the logs of a workload for parsable exceptions,. Use when triaging or monitoring Kubernetes, AKS, EKS workloads with skill template `k8s-tai...
runtime:
  runbook: runbook.robot
  monitor: sli.robot
  runner: ro
platforms: [Kubernetes, AKS, EKS, GKE, OpenShift, GoLang, Json, Python, CSharp, Django, Node, Java, FastAPI]
resource_types: [kubernetes_resource]
access: read-only
---

# Kubernetes Tail Application Logs

## Summary

This codebundle measures stack traces as they appear in your application logs and can produce reports for a breakdown of stack traces.

See [README.md](README.md) for additional context.

## Tools

### Get `${CONTAINER_NAME}` Application Logs in Namespace `${NAMESPACE}`

Collects the last approximately 300 lines of logs from the workload

- **Robot task name**: <code>Get `${CONTAINER_NAME}` Application Logs in Namespace `${NAMESPACE}`</code>
- **Robot file**: `runbook.robot`
- **Tags**: `access:read-only`, `resource`, `application`, `workload`, `logs`, `state`, `${container_name}`, `${workload_name}`, `data:logs-bulk`
- **Reads**: `CONTEXT`, `KUBERNETES_DISTRIBUTION_BINARY`, `LABELS`, `NAMESPACE`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Tail `${CONTAINER_NAME}` Application Logs For Stacktraces

Performs an inspection on container logs for exceptions/stacktraces, parsing them and attempts to find relevant source code information

- **Robot task name**: <code>Tail `${CONTAINER_NAME}` Application Logs For Stacktraces</code>
- **Robot file**: `runbook.robot`
- **Tags**: —
- **Reads**: `CONTEXT`, `INPUT_MODE`, `KUBERNETES_DISTRIBUTION_BINARY`, `LABELS`, `NAMESPACE`, `STACKTRACE_PARSER`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


## Monitor

Measures the number of exception stacktraces present in an application's logs over a time period.

- **Robot file**: `sli.robot`
- **Score range**: `0.0` (failing) to `1.0` (healthy)
- **Aggregation**: arithmetic mean of the sub-checks below
- **Recommended interval**: `180s`

### Sub-checks

#### Tail `${CONTAINER_NAME}` Application Logs For Stacktraces

Tails logs and organizes output for measuring counts.

- **Robot task name**: <code>Tail `${CONTAINER_NAME}` Application Logs For Stacktraces</code>
- **Sub-metric name**: `log_analysis`
- **Tags**: `resource`, `application`, `workload`, `logs`, `state`, `exceptions`, `errors`, `data:logs-stacktrace`
- **Reads**: `CONTEXT`, `INPUT_MODE`, `KUBERNETES_DISTRIBUTION_BINARY`, `LABELS`, `NAMESPACE`, `STACKTRACE_PARSER`


## Inputs

| Name | Type | Description | Default | Required |
|---|---|---|---|---|
| `NAMESPACE` | string | The name of the Kubernetes namespace to scope actions and searching to. | `sock-shop` | no |
| `CONTEXT` | string | Which Kubernetes context to operate within. | `sandbox-cluster-1` | no |
| `KUBERNETES_DISTRIBUTION_BINARY` | string | Which binary to use for Kubernetes CLI commands. | `kubectl` | no |
| `LABELS` | string | The Kubernetes labels used to select the resource for logs. | — | yes |
| `STACKTRACE_PARSER` | string | What parser implementation to use when going through logs. Dynamic will use the first successful parser which is more computationally expensive. | `Dynamic` | no |
| `INPUT_MODE` | string | Changes ingestion style of logs, typically split (1 log per line) works best. | `SPLIT` | no |

## Secrets

_No secrets imported in Robot source._

## Outputs

- Monitor health score (`0.0`–`1.0`) pushed by `sli.robot`

## How to invoke

### Preferred: Robot Framework runner (`ro`)

```bash
cd codebundles/k8s-tail-logs-dynamic
export NAMESPACE=...
export CONTEXT=...
export KUBERNETES_DISTRIBUTION_BINARY=...
export LABELS=...
export STACKTRACE_PARSER=...
export INPUT_MODE=...
ro runbook.robot
```

### Standalone scripts (no Robot)


_No standalone shell scripts in this bundle._

## Source files

- `runbook.robot` — orchestrates tools and raises issues
- `sli.robot` — monitor scoring (`sli.robot` runtime file)
