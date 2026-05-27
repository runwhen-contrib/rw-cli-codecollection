---
name: k8s-daemonset-healthcheck
description: Triages issues related to a DaemonSet and its pods, including node scheduling and resource constraints. Use when triaging or monitoring Kubernetes, AKS, EKS workloads with skill template `k8s-daemo...
runtime:
  runbook: runbook.robot
  runner: ro
platforms: [Kubernetes, AKS, EKS, GKE, OpenShift]
resource_types: [daemonset]
access: read-only
---

# Kubernetes DaemonSet Triage

## Summary

This codebundle provides a suite of tasks aimed at triaging issues related to a daemonset and its replicas in Kubernetes clusters.

See [README.md](README.md) for additional context.

## Tools

### Analyze Application Log Patterns for DaemonSet `${DAEMONSET_NAME}` in Namespace `${NAMESPACE}`

Fetches and analyzes logs from the DaemonSet pods for errors, stack traces, connection issues, and other patterns that indicate application health problems.

- **Robot task name**: <code>Analyze Application Log Patterns for DaemonSet `${DAEMONSET_NAME}` in Namespace `${NAMESPACE}`</code>
- **Robot file**: `runbook.robot`
- **Tags**: —
- **Reads**: `CONTEXT`, `DAEMONSET_NAME`, `LOG_AGE`, `LOG_ANALYSIS_DEPTH`, `LOG_SEVERITY_THRESHOLD`, `NAMESPACE`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Detect Log Anomalies for DaemonSet `${DAEMONSET_NAME}` in Namespace `${NAMESPACE}`

Analyzes logs for repeating patterns, anomalous behavior, and unusual log volume that may indicate underlying issues.

- **Robot task name**: <code>Detect Log Anomalies for DaemonSet `${DAEMONSET_NAME}` in Namespace `${NAMESPACE}`</code>
- **Robot file**: `runbook.robot`
- **Tags**: —
- **Reads**: `CONTEXT`, `DAEMONSET_NAME`, `LOG_AGE`, `NAMESPACE`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Identify Recent Configuration Changes for DaemonSet `${DAEMONSET_NAME}` in Namespace `${NAMESPACE}`

Identifies recent configuration changes from ControllerRevision analysis that might be related to current issues.

- **Robot task name**: <code>Identify Recent Configuration Changes for DaemonSet `${DAEMONSET_NAME}` in Namespace `${NAMESPACE}`</code>
- **Robot file**: `runbook.robot`
- **Tags**: —
- **Reads**: `CONTEXT`, `DAEMONSET_NAME`, `NAMESPACE`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Check Liveness Probe Configuration for DaemonSet `${DAEMONSET_NAME}`

Validates if a Liveness probe has possible misconfigurations

- **Robot task name**: <code>Check Liveness Probe Configuration for DaemonSet `${DAEMONSET_NAME}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `validate_probes.sh`
- **Tags**: —
- **Reads**: `CONTEXT`, `DAEMONSET_NAME`, `NAMESPACE`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Check Readiness Probe Configuration for DaemonSet `${DAEMONSET_NAME}` in Namespace `${NAMESPACE}`

Validates if a readiness probe has possible misconfigurations

- **Robot task name**: <code>Check Readiness Probe Configuration for DaemonSet `${DAEMONSET_NAME}` in Namespace `${NAMESPACE}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `validate_probes.sh`
- **Tags**: —
- **Reads**: `CONTEXT`, `DAEMONSET_NAME`, `NAMESPACE`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Check for Container Restarts in DaemonSet `${DAEMONSET_NAME}` in Namespace `${NAMESPACE}`

Analyzes container restart patterns in the DaemonSet pods to identify the root cause of restarts, distinguishing between OOM kills, liveness probe failures, and other termination causes.

- **Robot task name**: <code>Check for Container Restarts in DaemonSet `${DAEMONSET_NAME}` in Namespace `${NAMESPACE}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `container_restarts.sh`
- **Tags**: `access:read-only`, `containers`, `restarts`, `errors`, `oom`, `probes`, `daemonset`, `${DAEMONSET_NAME}`, `data:config`
- **Reads**: `DAEMONSET_NAME`, `NAMESPACE`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Inspect DaemonSet Warning Events for `${DAEMONSET_NAME}` in Namespace `${NAMESPACE}`

Fetches warning events related to the DaemonSet workload in the namespace and triages any issues found in the events.

- **Robot task name**: <code>Inspect DaemonSet Warning Events for `${DAEMONSET_NAME}` in Namespace `${NAMESPACE}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `workload_issues.sh`
- **Tags**: `access:read-only`, `events`, `workloads`, `errors`, `warnings`, `get`, `daemonset`, `${DAEMONSET_NAME}`, `data:config`
- **Reads**: `CONTEXT`, `DAEMONSET_NAME`, `KUBERNETES_DISTRIBUTION_BINARY`, `NAMESPACE`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Fetch DaemonSet Workload Details For `${DAEMONSET_NAME}` in Namespace `${NAMESPACE}`

Fetches the current state of the DaemonSet for future review in the report.

- **Robot task name**: <code>Fetch DaemonSet Workload Details For `${DAEMONSET_NAME}` in Namespace `${NAMESPACE}`</code>
- **Robot file**: `runbook.robot`
- **Tags**: `access:read-only`, `daemonset`, `details`, `manifest`, `info`, `${DAEMONSET_NAME}`, `data:config`
- **Reads**: `CONTEXT`, `DAEMONSET_NAME`, `KUBERNETES_DISTRIBUTION_BINARY`, `NAMESPACE`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Inspect DaemonSet Status for `${DAEMONSET_NAME}` in namespace `${NAMESPACE}`

Pulls the status information for a given DaemonSet and checks if all pods are properly scheduled and running across nodes, identifying node scheduling issues.

- **Robot task name**: <code>Inspect DaemonSet Status for `${DAEMONSET_NAME}` in namespace `${NAMESPACE}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `workload_next_steps.sh`
- **Tags**: —
- **Reads**: `CONTEXT`, `DAEMONSET_NAME`, `KUBERNETES_DISTRIBUTION_BINARY`, `NAMESPACE`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Check Node Affinity and Tolerations for DaemonSet `${DAEMONSET_NAME}` in Namespace `${NAMESPACE}`

Checks the node affinity, tolerations, and scheduling constraints of the DaemonSet to identify potential scheduling issues.

- **Robot task name**: <code>Check Node Affinity and Tolerations for DaemonSet `${DAEMONSET_NAME}` in Namespace `${NAMESPACE}`</code>
- **Robot file**: `runbook.robot`
- **Tags**: —
- **Reads**: `CONTEXT`, `DAEMONSET_NAME`, `KUBERNETES_DISTRIBUTION_BINARY`, `NAMESPACE`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


## Inputs

| Name | Type | Description | Default | Required |
|---|---|---|---|---|
| `KUBERNETES_DISTRIBUTION_BINARY` | string | Which binary to use for Kubernetes CLI commands. | `kubectl` | no |
| `CONTEXT` | string | Which Kubernetes context to operate within. | — | yes |
| `NAMESPACE` | string | The name of the Kubernetes namespace to scope actions and searching to. | — | yes |
| `DAEMONSET_NAME` | string | The name of the DaemonSet to triage. | — | yes |
| `LOG_AGE` | string | The age of logs to fetch from pods, used for log analysis tasks. | `3h` | no |
| `LOG_ANALYSIS_DEPTH` | string | The depth of log analysis to perform - basic, standard, or comprehensive. | `standard` | no |
| `LOG_SEVERITY_THRESHOLD` | string | The minimum severity level for creating issues (1=critical, 2=high, 3=medium, 4=low, 5=info). | `3` | no |
| `LOG_PATTERN_CATEGORIES` | string | Comma-separated list of log pattern categories to scan for. | `GenericError,AppFailure,StackTrace,Connection,Timeout,Auth,Exceptions,Resource` | no |
| `ANOMALY_THRESHOLD` | string | The threshold for detecting event anomalies based on events per minute. | `5` | no |
| `CONTAINER_RESTART_AGE` | string | The time window (in (h) hours or (m) minutes) to search for container restarts. Only containers that restarted within this time period will be reported. | `10m` | no |
| `CONTAINER_RESTART_THRESHOLD` | string | The minimum number of restarts required to trigger an issue. Containers with restart counts below this threshold will be ignored. | `1` | no |
| `EXCLUDED_CONTAINER_NAMES` | string | Comma-separated list of container names to exclude from log analysis (e.g., linkerd-proxy, istio-proxy, vault-agent). | `linkerd-proxy,istio-proxy,vault-agent` | no |

## Secrets

_No secrets imported in Robot source._

## Outputs

_See Robot run output and platform report artifacts._

## How to invoke

### Preferred: Robot Framework runner (`ro`)

```bash
cd codebundles/k8s-daemonset-healthcheck
export KUBERNETES_DISTRIBUTION_BINARY=...
export CONTEXT=...
export NAMESPACE=...
export DAEMONSET_NAME=...
export LOG_AGE=...
export LOG_ANALYSIS_DEPTH=...
ro runbook.robot
```

### Standalone scripts (no Robot)


Set the input variables above, then run the matching script:

```bash
cd codebundles/k8s-daemonset-healthcheck
export KUBERNETES_DISTRIBUTION_BINARY=...
export CONTEXT=...
export NAMESPACE=...
export DAEMONSET_NAME=...
bash container_restarts.sh
bash track_daemonset_config_changes.sh
bash validate_probes.sh
bash workload_issues.sh
bash workload_next_steps.sh
```

## Source files

- `runbook.robot` — orchestrates tools and raises issues
- `container_restarts.sh` — Bash helper script `container_restarts.sh`.
- `track_daemonset_config_changes.sh` — Bash helper script `track_daemonset_config_changes.sh`.
- `validate_probes.sh` — Bash helper script `validate_probes.sh`.
- `workload_issues.sh` — Bash helper script `workload_issues.sh`.
- `workload_next_steps.sh` — Bash helper script `workload_next_steps.sh`.
