---
name: k8s-cluster-node-health
kind: skill-template
description: Evaluate cluster node health using kubectl. Use when triaging or monitoring Kubernetes, AKS, EKS workloads with skill template `k8s-cluster-node-health`.
runtime:
  runbook: runbook.robot
  monitor: sli.robot
  runner: ro
platforms: [Kubernetes, AKS, EKS, GKE, OpenShift]
resource_types: [kubernetes_resource]
access: read-only
---

# Kubernetes Cluster Node Health

## Summary

The Service Level Indicator will generate a score for the health of the nodes in the cluster.

See [README.md](README.md) for additional context.

## Tools

### Check for Node Restarts in Cluster `${CONTEXT}` within Interval `${RW_LOOKBACK_WINDOW}`

Identify nodes that are starting and stopping within the time interval.

- **Robot task name**: <code>Check for Node Restarts in Cluster `${CONTEXT}` within Interval `${RW_LOOKBACK_WINDOW}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `node_restart_check.sh`
- **Tags**: `cluster`, `preempt`, `spot`, `reboot`, `utilization`, `saturation`, `exhaustion`, `access:read-only`, `data:config`
- **Reads**: `CONTEXT`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


## Monitor

Evaluate cluster node health using kubectl.

- **Robot file**: `sli.robot`
- **Score range**: `0.0` (failing) to `1.0` (healthy)
- **Aggregation**: arithmetic mean of the sub-checks below
- **Recommended interval**: `180s`

### Sub-checks

#### Generate Namespace Score in Kubernetes Cluster `$${CONTEXT}`

_No sub-check documentation in Robot source._

- **Robot task name**: <code>Generate Namespace Score in Kubernetes Cluster `$${CONTEXT}`</code>
- **Sub-metric name**: `node_health`
- **Tags**: —
- **Reads**: —


## Inputs

| Name | Type | Description | Default | Required |
|---|---|---|---|---|
| `KUBERNETES_DISTRIBUTION_BINARY` | string | Which binary to use for Kubernetes CLI commands. | `kubectl` | no |
| `CONTEXT` | string | Which Kubernetes context to operate within. | `default` | no |
| `INTERVAL` | string | The time interval in which to look back for node events. | `10 minutes` | no |

## Secrets

_No secrets imported in Robot source._

## Outputs

- Monitor health score (`0.0`–`1.0`) pushed by `sli.robot`

## How to invoke

### Preferred: Robot Framework runner (`ro`)

```bash
cd codebundles/k8s-cluster-node-health
export KUBERNETES_DISTRIBUTION_BINARY=...
export CONTEXT=...
export INTERVAL=...
ro runbook.robot
```

### Standalone scripts (no Robot)


Set the input variables above, then run the matching script:

```bash
cd codebundles/k8s-cluster-node-health
export KUBERNETES_DISTRIBUTION_BINARY=...
export CONTEXT=...
export INTERVAL=...
bash node_restart_check.sh
```

## Source files

- `runbook.robot` — orchestrates tools and raises issues
- `sli.robot` — monitor scoring (`sli.robot` runtime file)
- `node_restart_check.sh` — Bash helper script `node_restart_check.sh`.
