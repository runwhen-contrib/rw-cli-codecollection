---
name: k8s-statefulset-healthcheck
description: Triages issues related to a StatefulSet and its pods, including persistent volumes and ordered deployment... Use when triaging or monitoring Kubernetes, AKS, EKS workloads with skill template `k8s-...
runtime:
  runbook: runbook.robot
  monitor: sli.robot
  runner: ro
platforms: [Kubernetes, AKS, EKS, GKE, OpenShift]
resource_types: [statefulset]
access: read-only
---

# Kubernetes StatefulSet Triage

## Summary

This codebundle ships two robots that work together to keep an eye on a single Kubernetes StatefulSet: - `sli.robot` – a lightweight health score (0.0 – 1.0) published as a RunWhen SLI..

See [README.md](README.md) for additional context.

## Tools

### Analyze Application Log Patterns for StatefulSet `${STATEFULSET_NAME}` in Namespace `${NAMESPACE}`

Fetches and analyzes logs from the StatefulSet pods for errors, stack traces, connection issues, and other patterns that indicate application health problems.

- **Robot task name**: <code>Analyze Application Log Patterns for StatefulSet `${STATEFULSET_NAME}` in Namespace `${NAMESPACE}`</code>
- **Robot file**: `runbook.robot`
- **Tags**: —
- **Reads**: `CONTEXT`, `LOG_AGE`, `LOG_ANALYSIS_DEPTH`, `LOG_SEVERITY_THRESHOLD`, `NAMESPACE`, `STATEFULSET_NAME`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Detect Log Anomalies for StatefulSet `${STATEFULSET_NAME}` in Namespace `${NAMESPACE}`

Analyzes logs for repeating patterns, anomalous behavior, and unusual log volume that may indicate underlying issues.

- **Robot task name**: <code>Detect Log Anomalies for StatefulSet `${STATEFULSET_NAME}` in Namespace `${NAMESPACE}`</code>
- **Robot file**: `runbook.robot`
- **Tags**: —
- **Reads**: `CONTEXT`, `LOG_AGE`, `NAMESPACE`, `STATEFULSET_NAME`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Check Liveness Probe Configuration for StatefulSet `${STATEFULSET_NAME}`

Validates if a Liveness probe has possible misconfigurations

- **Robot task name**: <code>Check Liveness Probe Configuration for StatefulSet `${STATEFULSET_NAME}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `validate_probes.sh`
- **Tags**: —
- **Reads**: `CONTEXT`, `NAMESPACE`, `STATEFULSET_NAME`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Check Readiness Probe Configuration for StatefulSet `${STATEFULSET_NAME}` in Namespace `${NAMESPACE}`

Validates if a readiness probe has possible misconfigurations

- **Robot task name**: <code>Check Readiness Probe Configuration for StatefulSet `${STATEFULSET_NAME}` in Namespace `${NAMESPACE}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `validate_probes.sh`
- **Tags**: —
- **Reads**: `CONTEXT`, `NAMESPACE`, `STATEFULSET_NAME`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Check for Container Restarts in StatefulSet `${STATEFULSET_NAME}` in Namespace `${NAMESPACE}`

Analyzes container restart patterns in the StatefulSet pods to identify the root cause of restarts, distinguishing between OOM kills, liveness probe failures, and other termination causes.

- **Robot task name**: <code>Check for Container Restarts in StatefulSet `${STATEFULSET_NAME}` in Namespace `${NAMESPACE}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `container_restarts.sh`
- **Tags**: `access:read-only`, `containers`, `restarts`, `errors`, `oom`, `probes`, `statefulset`, `${STATEFULSET_NAME}`, `data:config`
- **Reads**: `NAMESPACE`, `STATEFULSET_NAME`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Inspect StatefulSet Warning Events for `${STATEFULSET_NAME}` in Namespace `${NAMESPACE}`

Fetches warning events related to the StatefulSet workload in the namespace and triages any issues found in the events.

- **Robot task name**: <code>Inspect StatefulSet Warning Events for `${STATEFULSET_NAME}` in Namespace `${NAMESPACE}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `workload_issues.sh`
- **Tags**: `access:read-only`, `events`, `workloads`, `errors`, `warnings`, `get`, `statefulset`, `${STATEFULSET_NAME}`, `data:config`
- **Reads**: `CONTEXT`, `KUBERNETES_DISTRIBUTION_BINARY`, `NAMESPACE`, `STATEFULSET_NAME`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Fetch StatefulSet Workload Details For `${STATEFULSET_NAME}` in Namespace `${NAMESPACE}`

Fetches the current state of the StatefulSet for future review in the report.

- **Robot task name**: <code>Fetch StatefulSet Workload Details For `${STATEFULSET_NAME}` in Namespace `${NAMESPACE}`</code>
- **Robot file**: `runbook.robot`
- **Tags**: `access:read-only`, `statefulset`, `details`, `manifest`, `info`, `${STATEFULSET_NAME}`, `data:config`
- **Reads**: `CONTEXT`, `KUBERNETES_DISTRIBUTION_BINARY`, `NAMESPACE`, `STATEFULSET_NAME`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Inspect StatefulSet Replicas for `${STATEFULSET_NAME}` in namespace `${NAMESPACE}`

Pulls the replica information for a given StatefulSet and checks if it's highly available, if the replica counts are the expected / healthy values, and raises issues if it is not progressing and is missing pods. Includes StatefulSet-specific checks for ordered deployment.

- **Robot task name**: <code>Inspect StatefulSet Replicas for `${STATEFULSET_NAME}` in namespace `${NAMESPACE}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `workload_next_steps.sh`
- **Tags**: —
- **Reads**: `CONTEXT`, `KUBERNETES_DISTRIBUTION_BINARY`, `NAMESPACE`, `STATEFULSET_NAME`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Check StatefulSet PersistentVolumeClaims for `${STATEFULSET_NAME}` in Namespace `${NAMESPACE}`

Checks the status of PersistentVolumeClaims associated with the StatefulSet and identifies storage-related issues.

- **Robot task name**: <code>Check StatefulSet PersistentVolumeClaims for `${STATEFULSET_NAME}` in Namespace `${NAMESPACE}`</code>
- **Robot file**: `runbook.robot`
- **Tags**: —
- **Reads**: `CONTEXT`, `KUBERNETES_DISTRIBUTION_BINARY`, `NAMESPACE`, `STATEFULSET_NAME`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Identify Recent Configuration Changes for StatefulSet `${STATEFULSET_NAME}` in Namespace `${NAMESPACE}`

Identifies recent configuration changes from ControllerRevision analysis that might be related to current issues.

- **Robot task name**: <code>Identify Recent Configuration Changes for StatefulSet `${STATEFULSET_NAME}` in Namespace `${NAMESPACE}`</code>
- **Robot file**: `runbook.robot`
- **Tags**: —
- **Reads**: `CONTEXT`, `NAMESPACE`, `STATEFULSET_NAME`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


## Monitor

This SLI uses kubectl to score StatefulSet health. Produces a value between 0 (completely failing the test) and 1 (fully passing the test). Looks for container restarts, critical log errors, pods not ready, StatefulSet replica/revision status, PersistentVolumeClaim binding, and recent warning events.

- **Robot file**: `sli.robot`
- **Score range**: `0.0` (failing) to `1.0` (healthy)
- **Aggregation**: arithmetic mean of the sub-checks below
- **Recommended interval**: `180s`

### Sub-checks

#### Get Container Restarts and Score for StatefulSet `${STATEFULSET_NAME}`

Counts the total sum of container restarts within a timeframe and determines if they're beyond a threshold.

- **Robot task name**: <code>Get Container Restarts and Score for StatefulSet `${STATEFULSET_NAME}`</code>
- **Sub-metric name**: `container_restarts`
- **Tags**: `Restarts`, `Pods`, `Containers`, `Count`, `Status`, `data:config`
- **Reads**: `CONTAINER_RESTART_AGE`, `CONTAINER_RESTART_THRESHOLD`, `CONTEXT`, `KUBERNETES_DISTRIBUTION_BINARY`, `NAMESPACE`
- **Pass condition**: `${restart_count} <= ${threshold}`


#### Get Critical Log Errors and Score for StatefulSet `${STATEFULSET_NAME}`

Fetches logs and checks for critical error patterns that indicate application failures.

- **Robot task name**: <code>Get Critical Log Errors and Score for StatefulSet `${STATEFULSET_NAME}`</code>
- **Sub-metric name**: `log_errors`
- **Tags**: `logs`, `errors`, `critical`, `patterns`, `data:logs-regexp`
- **Reads**: `CONTEXT`, `LOGS_EXCLUDE_PATTERN`, `MAX_LOG_BYTES`, `MAX_LOG_LINES`, `NAMESPACE`, `STATEFULSET_NAME`


#### Get NotReady Pods Score for StatefulSet `${STATEFULSET_NAME}`

Fetches a count of unready pods for the specific StatefulSet.

- **Robot task name**: <code>Get NotReady Pods Score for StatefulSet `${STATEFULSET_NAME}`</code>
- **Sub-metric name**: `pod_readiness`
- **Tags**: `access:read-only`, `Pods`, `Status`, `Phase`, `Ready`, `Unready`, `Running`, `data:config`
- **Reads**: `CONTEXT`, `KUBERNETES_DISTRIBUTION_BINARY`, `NAMESPACE`
- **Pass condition**: `${unready_count} == 0`


#### Get StatefulSet Replica Status and Score for `${STATEFULSET_NAME}`

Checks if the StatefulSet has the expected number of ready replicas and that all pods are on the latest revision.

- **Robot task name**: <code>Get StatefulSet Replica Status and Score for `${STATEFULSET_NAME}`</code>
- **Sub-metric name**: `replica_status`
- **Tags**: `statefulset`, `replicas`, `revisions`, `status`, `availability`, `data:config`
- **Reads**: `CONTEXT`, `KUBERNETES_DISTRIBUTION_BINARY`, `NAMESPACE`, `STATEFULSET_NAME`


#### Get PersistentVolumeClaim Status and Score for StatefulSet `${STATEFULSET_NAME}`

Checks that PersistentVolumeClaims associated with the StatefulSet are Bound. Unbound PVCs commonly keep StatefulSet pods from starting.

- **Robot task name**: <code>Get PersistentVolumeClaim Status and Score for StatefulSet `${STATEFULSET_NAME}`</code>
- **Sub-metric name**: `pvc_status`
- **Tags**: `statefulset`, `pvc`, `storage`, `persistent`, `data:config`
- **Reads**: `CONTEXT`, `KUBERNETES_DISTRIBUTION_BINARY`, `NAMESPACE`, `STATEFULSET_NAME`


#### Get Recent Warning Events Score for StatefulSet `${STATEFULSET_NAME}`

Checks for recent warning events related to the StatefulSet, its pods, and its PersistentVolumeClaims within a short time window.

- **Robot task name**: <code>Get Recent Warning Events Score for StatefulSet `${STATEFULSET_NAME}`</code>
- **Sub-metric name**: `warning_events`
- **Tags**: `events`, `warnings`, `recent`, `fast`, `data:config`
- **Reads**: `CONTEXT`, `EVENT_AGE`, `EVENT_THRESHOLD`, `KUBERNETES_DISTRIBUTION_BINARY`, `NAMESPACE`, `STATEFULSET_NAME`
- **Pass condition**: `${event_count} <= ${threshold} else (0.5 if ${event_count} <= ${threshold_doubled}`


## Inputs

| Name | Type | Description | Default | Required |
|---|---|---|---|---|
| `KUBERNETES_DISTRIBUTION_BINARY` | string | Which binary to use for Kubernetes CLI commands. | `kubectl` | no |
| `CONTEXT` | string | Which Kubernetes context to operate within. | — | yes |
| `NAMESPACE` | string | The name of the Kubernetes namespace to scope actions and searching to. | — | yes |
| `STATEFULSET_NAME` | string | The name of the StatefulSet to triage. | — | yes |
| `LOG_AGE` | string | The age of logs to fetch from pods, used for log analysis tasks. | `3h` | no |
| `LOG_ANALYSIS_DEPTH` | string | The depth of log analysis to perform - basic, standard, or comprehensive. | `standard` | no |
| `LOG_SEVERITY_THRESHOLD` | string | The minimum severity level for creating issues (1=critical, 2=high, 3=medium, 4=low, 5=info). | `3` | no |
| `LOG_PATTERN_CATEGORIES` | string | Comma-separated list of log pattern categories to scan for. | `GenericError,AppFailure,StackTrace,Connection,Timeout,Auth,Exceptions,Resource` | no |
| `ANOMALY_THRESHOLD` | string | The threshold for detecting event anomalies based on events per minute. | `5` | no |
| `CONTAINER_RESTART_AGE` | string | The time window (in (h) hours or (m) minutes) to search for container restarts. Only containers that restarted within this time period will be reported. | `10m` | no |
| `CONTAINER_RESTART_THRESHOLD` | string | The minimum number of restarts required to trigger an issue. Containers with restart counts below this threshold will be ignored. | `1` | no |
| `EXCLUDED_CONTAINER_NAMES` | string | Comma-separated list of container names to exclude from log analysis (e.g., linkerd-proxy, istio-proxy, vault-agent). | `linkerd-proxy,istio-proxy,vault-agent` | no |
| `MAX_LOG_LINES` | string | Maximum number of log lines to fetch per container to prevent API overload. | `100` | no |
| `MAX_LOG_BYTES` | string | Maximum log size in bytes to fetch per container to prevent API overload. | `256000` | no |
| `EVENT_AGE` | string | The time window to check for recent warning events. | `10m` | no |
| `EVENT_THRESHOLD` | string | The maximum number of critical warning events allowed before scoring is reduced. | `2` | no |
| `LOGS_EXCLUDE_PATTERN` | string | Pattern used to exclude entries from log analysis when searching for errors. Use regex patterns to filter out false positives like JSON structures. | `"errors":\s*\[\]|\\bINFO\\b|\\bDEBUG\\b|\\bTRACE\\b|\\bSTART\\s*-\\s*|\\bSTART\\s*method\\b` | no |

## Secrets

| Name | Description | Required |
|---|---|---|
| `kubeconfig` | The kubernetes kubeconfig yaml containing connection configuration used to connect to cluster(s). | yes |

## Outputs

- Monitor health score (`0.0`–`1.0`) pushed by `sli.robot`

## How to invoke

### Preferred: Robot Framework runner (`ro`)

```bash
cd codebundles/k8s-statefulset-healthcheck
export KUBERNETES_DISTRIBUTION_BINARY=...
export CONTEXT=...
export NAMESPACE=...
export STATEFULSET_NAME=...
export LOG_AGE=...
export LOG_ANALYSIS_DEPTH=...
ro runbook.robot
```

### Standalone scripts (no Robot)


Set the input variables above, then run the matching script:

```bash
cd codebundles/k8s-statefulset-healthcheck
export KUBERNETES_DISTRIBUTION_BINARY=...
export CONTEXT=...
export NAMESPACE=...
export STATEFULSET_NAME=...
bash container_restarts.sh
bash track_statefulset_config_changes.sh
bash validate_probes.sh
bash workload_issues.sh
bash workload_next_steps.sh
```

## Source files

- `runbook.robot` — orchestrates tools and raises issues
- `sli.robot` — monitor scoring (`sli.robot` runtime file)
- `container_restarts.sh` — Bash helper script `container_restarts.sh`.
- `track_statefulset_config_changes.sh` — Bash helper script `track_statefulset_config_changes.sh`.
- `validate_probes.sh` — Bash helper script `validate_probes.sh`.
- `workload_issues.sh` — Bash helper script `workload_issues.sh`.
- `workload_next_steps.sh` — Bash helper script `workload_next_steps.sh`.
