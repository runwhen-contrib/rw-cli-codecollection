---
name: k8s-stacktrace-health
kind: skill-template
description: Detects and analyzes stacktraces/tracebacks in Kubernetes workload logs for troubleshooting application issues. Use when triaging or monitoring Kubernetes, AKS, EKS workloads with skill template `k...
runtime:
  runbook: runbook.robot
  monitor: sli.robot
  executor: worker
  entrypoint: /home/runwhen/robot-runtime/runrobot.sh
  base_image: rw-base-runtime
platforms: [Kubernetes, AKS, EKS, GKE, OpenShift]
resource_types: [kubernetes_resource]
access: read-only
---

# Kubernetes Workload Stacktrace Analysis

## Summary

This codebundle provides comprehensive stacktrace/traceback detection and analysis for Kubernetes workloads (deployments, statefulsets, and daemonsets).

See [README.md](README.md) for additional context.

## Tools

### Analyze Workload Stacktraces for ${WORKLOAD_TYPE} `${WORKLOAD_NAME}` in Namespace `${NAMESPACE}`

Collects and analyzes stacktraces/tracebacks from all pods in the workload for troubleshooting application issues.

- **Robot task name**: <code>Analyze Workload Stacktraces for ${WORKLOAD_TYPE} `${WORKLOAD_NAME}` in Namespace `${NAMESPACE}`</code>
- **Robot file**: `runbook.robot`
- **Tags**: —
- **Reads**: `CONTEXT`, `EXCLUDED_CONTAINER_NAMES`, `LOG_AGE`, `LOG_LINES`, `LOG_SIZE`, `NAMESPACE`, `WORKLOAD_NAME`, `WORKLOAD_TYPE`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


## Monitor

This SLI monitors stacktrace health in kubernetes workload application logs. Produces a value between 0 (stacktraces detected) and 1 (no stacktraces found). Focuses specifically on application error detection through stacktrace analysis.

- **Robot file**: `sli.robot`
- **Score range**: `0.0` (failing) to `1.0` (healthy)
- **Aggregation**: arithmetic mean of the sub-checks below
- **Recommended interval**: `180s`

### Sub-checks

#### Get Stacktrace Health Score for ${WORKLOAD_TYPE} `${WORKLOAD_NAME}`

Checks for recent stacktraces/tracebacks related to the workload within a short time window, with filtering to reduce noise.

- **Robot task name**: <code>Get Stacktrace Health Score for ${WORKLOAD_TYPE} `${WORKLOAD_NAME}`</code>
- **Sub-metric name**: `stacktrace_score`
- **Tags**: `stacktraces`, `tracebacks`, `errors`, `recent`, `fast`, `data:logs-stacktrace`
- **Reads**: `CONTEXT`, `MAX_LOG_BYTES`, `MAX_LOG_LINES`, `NAMESPACE`, `WORKLOAD_NAME`, `WORKLOAD_TYPE`


## Inputs

| Name | Type | Description | Default | Required |
|---|---|---|---|---|
| `KUBERNETES_DISTRIBUTION_BINARY` | string | Which binary to use for Kubernetes CLI commands. | `kubectl` | no |
| `CONTEXT` | string | Which Kubernetes context to operate within. | — | yes |
| `NAMESPACE` | string | The name of the Kubernetes namespace to scope actions and searching to. | — | yes |
| `WORKLOAD_NAME` | string | The name of the workload (deployment, statefulset, or daemonset) to analyze for stacktraces. | — | yes |
| `WORKLOAD_TYPE` | string | The type of Kubernetes workload to analyze. | `deployment` | no |
| `LOG_LINES` | string | The number of log lines to fetch from the pods when inspecting logs. | `2000` | no |
| `LOG_AGE` | string | The age of logs to fetch from pods, used for log analysis tasks. | `15m` | no |
| `LOG_SIZE` | string | The maximum size of logs in bytes to fetch from pods, used for log analysis tasks. Defaults to 2MB. | `2097152` | no |
| `EXCLUDED_CONTAINER_NAMES` | string | comma-separated string of keywords used to identify and skip container names containing any of these substrings." | `linkerd-proxy,istio-proxy,vault-agent` | no |
| `MAX_LOG_LINES` | string | Maximum number of log lines to fetch per container to prevent API overload. | `2000` | no |
| `MAX_LOG_BYTES` | string | Maximum log size in bytes to fetch per container to prevent API overload. | `256000` | no |

## Secrets

| Name | Description | Required |
|---|---|---|
| `kubeconfig` | The kubernetes kubeconfig yaml containing connection configuration used to connect to cluster(s). | yes |

## Outputs

- Monitor health score (`0.0`–`1.0`) pushed by `sli.robot`

## How to invoke

### Production (RunWhen runner / worker)

The platform **runner** schedules work on a location **worker**. The worker
image (`rw-base-runtime`) executes Robot via `runrobot.sh` with
`RW_PATH_TO_ROBOT` set to the bound path under `/home/runwhen/collection/`.

- **Runbook**: `codebundles/k8s-stacktrace-health/runbook.robot`
- **Monitor**: `codebundles/k8s-stacktrace-health/sli.robot`

### Local development (devcontainer only)

`ro` is a dev-time wrapper in `codecollection-devtools` — not the enterprise runtime.

```bash
cd codebundles/k8s-stacktrace-health
export KUBERNETES_DISTRIBUTION_BINARY=...
export CONTEXT=...
export NAMESPACE=...
export WORKLOAD_NAME=...
export WORKLOAD_TYPE=...
export LOG_LINES=...
ro runbook.robot
```

### Standalone scripts (no Robot)


_No standalone shell scripts in this bundle._

## Source files

- `runbook.robot` — orchestrates tools and raises issues
- `sli.robot` — monitor scoring (`sli.robot` runtime file)
