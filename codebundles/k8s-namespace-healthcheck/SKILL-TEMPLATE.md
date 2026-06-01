---
name: k8s-namespace-healthcheck
kind: skill-template
description: This taskset runs general troubleshooting checks against all applicable objects in a namespace. Looks for warning... Use when triaging or monitoring Kubernetes, AKS, EKS workloads with skill templa...
runtime:
  runbook: runbook.robot
  monitor: sli.robot
  runner: ro
platforms: [Kubernetes, AKS, EKS, GKE, OpenShift]
resource_types: [namespace]
access: read-only
---

# Kubernetes Namespace Inspection

## Summary

This codebundle is used for searching in a namespace for possible issues to triage; covering things such as scraping logs, checking for anomalies in events, looking for pod restarts, etc.

See [README.md](README.md) for additional context.

## Tools

### Inspect Warning Events in Namespace `${NAMESPACE}`

Queries all warning events in a given namespace within the RW_LOOKBACK_WINDOW timeframe,

- **Robot task name**: <code>Inspect Warning Events in Namespace `${NAMESPACE}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `workload_issues.sh`
- **Tags**: `access:read-only`, `namespace`, `trace`, `error`, `pods`, `events`, `logs`, `grep`, `${NAMESPACE}`, `data:config`
- **Reads**: `CONTEXT`, `KUBERNETES_DISTRIBUTION_BINARY`, `NAMESPACE`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Inspect Container Restarts In Namespace `${NAMESPACE}`

Fetches pods that have container restarts and provides a detailed analysis of restart causes including proper OOM vs liveness probe failure detection.

- **Robot task name**: <code>Inspect Container Restarts In Namespace `${NAMESPACE}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `container_restarts.sh`
- **Tags**: `access:read-only`, `namespace`, `containers`, `status`, `restarts`, `${namespace}`, `data:config`
- **Reads**: `NAMESPACE`
- **Writes**: `container_restart_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Inspect Pending Pods In Namespace `${NAMESPACE}`

Fetches pods that are pending and provides details.

- **Robot task name**: <code>Inspect Pending Pods In Namespace `${NAMESPACE}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `workload_issues.sh`
- **Tags**: `access:read-only`, `namespace`, `pods`, `status`, `pending`, `${NAMESPACE}`, `data:config`
- **Reads**: `CONTEXT`, `KUBERNETES_DISTRIBUTION_BINARY`, `NAMESPACE`, `RW_LOOKBACK_WINDOW`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Inspect Failed Pods In Namespace `${NAMESPACE}`

Fetches all pods which are not running (unready) in the namespace and adds them to a report for future review.

- **Robot task name**: <code>Inspect Failed Pods In Namespace `${NAMESPACE}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `workload_issues.sh`
- **Tags**: `access:read-only`, `namespace`, `pods`, `status`, `unready`, `not`, `starting`, `phase`, `failed`, `${namespace}`, `data:config`
- **Reads**: `CONTEXT`, `KUBERNETES_DISTRIBUTION_BINARY`, `NAMESPACE`, `RW_LOOKBACK_WINDOW`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Inspect Workload Status Conditions In Namespace `${NAMESPACE}`

Parses all workloads in a namespace and inspects their status conditions for issues. Status conditions with a status value of False are considered an error.

- **Robot task name**: <code>Inspect Workload Status Conditions In Namespace `${NAMESPACE}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `workload_next_steps.sh`
- **Tags**: `access:read-only`, `namespace`, `status`, `conditions`, `pods`, `reasons`, `workloads`, `${namespace}`, `data:config`
- **Reads**: `CONTEXT`, `KUBERNETES_DISTRIBUTION_BINARY`, `NAMESPACE`, `RW_LOOKBACK_WINDOW`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Get Listing Of Resources In Namespace `${NAMESPACE}`

Simple fetch all to provide a snapshot of information about the workloads in the namespace for future review in a report.

- **Robot task name**: <code>Get Listing Of Resources In Namespace `${NAMESPACE}`</code>
- **Robot file**: `runbook.robot`
- **Tags**: `access:read-only`, `get`, `all`, `resources`, `info`, `workloads`, `namespace`, `manifests`, `${namespace}`, `data:config`
- **Reads**: `CONTEXT`, `KUBERNETES_DISTRIBUTION_BINARY`, `NAMESPACE`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Check Event Anomalies in Namespace `${NAMESPACE}`

Fetches non warning events in a namespace within a timeframe and checks for unusual activity, raising issues for any found.

- **Robot task name**: <code>Check Event Anomalies in Namespace `${NAMESPACE}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `workload_issues.sh`
- **Tags**: `access:read-only`, `namespace`, `events`, `info`, `state`, `anomolies`, `count`, `occurences`, `${namespace}`, `data:config`
- **Reads**: `CONTEXT`, `KUBERNETES_DISTRIBUTION_BINARY`, `NAMESPACE`, `RW_LOOKBACK_WINDOW`
- **Writes**: `events.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Check Missing or Risky PodDisruptionBudget Policies in Namepace `${NAMESPACE}`

Searches through deployemnts and statefulsets to determine if PodDistruptionBudgets are missing and/or are configured in a risky way that might affect maintenance activities.

- **Robot task name**: <code>Check Missing or Risky PodDisruptionBudget Policies in Namepace `${NAMESPACE}`</code>
- **Robot file**: `runbook.robot`
- **Tags**: —
- **Reads**: `CONTEXT`, `KUBERNETES_DISTRIBUTION_BINARY`, `NAMESPACE`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Check Resource Quota Utilization in Namespace `${NAMESPACE}`

Lists any namespace resource quotas and checks their utilization, raising issues if they are above 80%

- **Robot task name**: <code>Check Resource Quota Utilization in Namespace `${NAMESPACE}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `resource_quota_check.sh`
- **Tags**: `access:read-only`, `resourcequota`, `quota`, `availability`, `unavailable`, `policy`, `${namespace}`, `data:config`
- **Reads**: `NAMESPACE`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


## Monitor

This SLI uses kubectl to score namespace health. Produces a value between 0 (completely failing thet test) and 1 (fully passing the test). Looks for container restarts, events, and pods not ready.

- **Robot file**: `sli.robot`
- **Score range**: `0.0` (failing) to `1.0` (healthy)
- **Aggregation**: arithmetic mean of the sub-checks below
- **Recommended interval**: `180s`

### Sub-checks

#### Get Error Event Count within ${RW_LOOKBACK_WINDOW} and calculate Score

Captures error events and counts them within the RW_LOOKBACK_WINDOW timeframe, consistent with runbook analysis.

- **Robot task name**: <code>Get Error Event Count within ${RW_LOOKBACK_WINDOW} and calculate Score</code>
- **Sub-metric name**: `error_events`
- **Tags**: `Event`, `Count`, `Warning`, `data:config`
- **Reads**: `CONTEXT`, `EVENT_THRESHOLD`, `KUBERNETES_DISTRIBUTION_BINARY`, `NAMESPACE`, `RW_LOOKBACK_WINDOW`
- **Pass condition**: `${event_count} <= ${threshold}`


#### Get Container Restarts and Score in Namespace `${NAMESPACE}`

Counts the total sum of container restarts within a timeframe and determines if they're beyond a threshold.

- **Robot task name**: <code>Get Container Restarts and Score in Namespace `${NAMESPACE}`</code>
- **Sub-metric name**: `container_restarts`
- **Tags**: `Restarts`, `Pods`, `Containers`, `Count`, `Status`, `data:config`
- **Reads**: `CONTAINER_RESTART_THRESHOLD`, `CONTEXT`, `KUBERNETES_DISTRIBUTION_BINARY`, `NAMESPACE`, `RW_LOOKBACK_WINDOW`
- **Pass condition**: `${restart_count} <= ${threshold}`


#### Get NotReady Pods in `${NAMESPACE}`

Fetches a count of unready pods.

- **Robot task name**: <code>Get NotReady Pods in `${NAMESPACE}`</code>
- **Sub-metric name**: `pod_readiness`
- **Tags**: `access:read-only`, `Pods`, `Status`, `Phase`, `Ready`, `Unready`, `Running`, `data:config`
- **Reads**: `CONTEXT`, `KUBERNETES_DISTRIBUTION_BINARY`, `NAMESPACE`, `RW_LOOKBACK_WINDOW`
- **Pass condition**: `${unready_count} == 0`


## Inputs

| Name | Type | Description | Default | Required |
|---|---|---|---|---|
| `NAMESPACE` | string | The name of the Kubernetes namespace to scope actions and searching to. | — | yes |
| `CONTEXT` | string | Which Kubernetes context to operate within. | — | yes |
| `KUBERNETES_DISTRIBUTION_BINARY` | string | Which binary to use for Kubernetes CLI commands. | `kubectl` | no |
| `EVENT_AGE` | string | The time window in minutes as to when the event was last seen. | `30m` | no |
| `CONTAINER_RESTART_AGE` | string | The time window (in (h) hours or (m) minutes) as search for container restarts. | `4h` | no |
| `RW_LOOKBACK_WINDOW` | string | The time window (in (h) hours or (m) minutes) to look back for time-sensitive issues like failed pods, pending pods, workload status conditions, and event anomalies. Resources with issues older than this window will be ignored. | `1h` | no |
| `CONTAINER_RESTART_THRESHOLD` | string | The maximum total container restarts to be still considered healthy. | `3` | no |
| `EVENT_THRESHOLD` | string | The maximum total events to be still considered healthy. | `4` | no |

## Secrets

| Name | Description | Required |
|---|---|---|
| `kubeconfig` | The kubernetes kubeconfig yaml containing connection configuration used to connect to cluster(s). | yes |

## Outputs

- Monitor health score (`0.0`–`1.0`) pushed by `sli.robot`
- `container_restart_issues.json`
- `events.json`

## How to invoke

### Preferred: Robot Framework runner (`ro`)

```bash
cd codebundles/k8s-namespace-healthcheck
export NAMESPACE=...
export CONTEXT=...
export KUBERNETES_DISTRIBUTION_BINARY=...
export EVENT_AGE=...
export CONTAINER_RESTART_AGE=...
export RW_LOOKBACK_WINDOW=...
ro runbook.robot
```

### Standalone scripts (no Robot)


Set the input variables above, then run the matching script:

```bash
cd codebundles/k8s-namespace-healthcheck
export NAMESPACE=...
export CONTEXT=...
export KUBERNETES_DISTRIBUTION_BINARY=...
export EVENT_AGE=...
bash container_restarts.sh
bash find_resource_owners.sh
bash resource_quota_check.sh
bash warning_events.sh
bash workload_issues.sh
bash workload_next_steps.sh
```

## Source files

- `runbook.robot` — orchestrates tools and raises issues
- `sli.robot` — monitor scoring (`sli.robot` runtime file)
- `container_restarts.sh` — Bash helper script `container_restarts.sh`.
- `find_resource_owners.sh` — Bash helper script `find_resource_owners.sh`.
- `resource_quota_check.sh` — Bash helper script `resource_quota_check.sh`.
- `warning_events.sh` — Bash helper script `warning_events.sh`.
- `workload_issues.sh` — Bash helper script `workload_issues.sh`.
- `workload_next_steps.sh` — Bash helper script `workload_next_steps.sh`.
