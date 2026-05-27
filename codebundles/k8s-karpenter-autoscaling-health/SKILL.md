---
name: k8s-karpenter-autoscaling-health
description: Monitors Karpenter-driven autoscaling: NodePools, NodeClaims, pending workloads, controller logs, and cloud NodeClasses. Use when triaging or monitoring Kubernetes, Karpenter, Autoscaling workloads...
runtime:
  runbook: runbook.robot
  monitor: sli.robot
  runner: ro
platforms: [Kubernetes, Karpenter, Autoscaling, NodePool, NodeClaim, EKS, AKS, GKE]
resource_types: [kubernetes_resource]
access: read-only
---

# Kubernetes Karpenter Autoscaling Health

## Summary

This CodeBundle monitors Karpenter-driven autoscaling: NodePool or legacy Provisioner status, NodeClaim or Machine readiness, Pending workloads that indicate capacity or scheduling pressure, Karpenter controller logs, cloud NodeClass conditions, stuck NodeClaims, and optional log-to-pod correlation.

See [README.md](README.md) for additional context.

## Tools

### Summarize NodePool and NodeClaim Health in Cluster `${CONTEXT}`

Lists NodePools or Provisioners and NodeClaims or Machines, parses unhealthy status conditions, and summarizes not-ready or cordoned nodes.

- **Robot task name**: <code>Summarize NodePool and NodeClaim Health in Cluster `${CONTEXT}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `check-karpenter-nodepool-nodeclaim-status.sh`
- **Tags**: `Kubernetes`, `Karpenter`, `NodePool`, `NodeClaim`, `access:read-only`, `data:config`
- **Reads**: `CONTEXT`
- **Writes**: `karpenter_nodepool_nodeclaim_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Detect Workloads Blocked on Provisioning or Capacity in Cluster `${CONTEXT}`

Finds Pending pods whose status messages indicate insufficient capacity, scheduling failures, or topology spread constraints correlated with scaling pressure.

- **Robot task name**: <code>Detect Workloads Blocked on Provisioning or Capacity in Cluster `${CONTEXT}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `check-pending-provisioning-workloads.sh`
- **Tags**: `Kubernetes`, `Karpenter`, `Pending`, `scheduling`, `access:read-only`, `data:config`
- **Reads**: `CONTEXT`
- **Writes**: `karpenter_pending_workload_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Scan Karpenter Controller Logs for Errors in Namespace `${KARPENTER_NAMESPACE}`

Aggregates recent controller pod logs for ERROR, WARN, and known failure substrings within RW_LOOKBACK_WINDOW, capped for RBAC and volume safety.

- **Robot task name**: <code>Scan Karpenter Controller Logs for Errors in Namespace `${KARPENTER_NAMESPACE}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `scan-karpenter-controller-logs.sh`
- **Tags**: `Kubernetes`, `Karpenter`, `logs`, `controller`, `access:read-only`, `data:logs`
- **Reads**: `CONTEXT`, `KARPENTER_NAMESPACE`
- **Writes**: `karpenter_controller_log_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Check Cloud NodeClass Resources for Misconfiguration Signals in Cluster `${CONTEXT}`

Reads EC2NodeClass, legacy AWSNodeTemplate, or other provider NodeClass conditions for subnet, security group, AMI, or IAM-related failures.

- **Robot task name**: <code>Check Cloud NodeClass Resources for Misconfiguration Signals in Cluster `${CONTEXT}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `check-karpenter-nodeclass-conditions.sh`
- **Tags**: `Kubernetes`, `Karpenter`, `NodeClass`, `AWS`, `access:read-only`, `data:config`
- **Reads**: `CONTEXT`
- **Writes**: `karpenter_nodeclass_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Identify Stale or Stuck NodeClaims in Cluster `${CONTEXT}`

Finds NodeClaims that remain non-ready past STUCK_NODECLAIM_THRESHOLD_MINUTES or show prolonged deletion, indicating consolidation or lifecycle issues.

- **Robot task name**: <code>Identify Stale or Stuck NodeClaims in Cluster `${CONTEXT}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `check-stuck-nodeclaims.sh`
- **Tags**: `Kubernetes`, `Karpenter`, `NodeClaim`, `stuck`, `access:read-only`, `data:config`
- **Reads**: `CONTEXT`
- **Writes**: `karpenter_stuck_nodeclaim_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Correlate Recent Karpenter Log Patterns with Pending Pods in Cluster `${CONTEXT}`

Optional cross-check that links controller log lines to Pending pod names when both appear together for faster triage.

- **Robot task name**: <code>Correlate Recent Karpenter Log Patterns with Pending Pods in Cluster `${CONTEXT}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `correlate-karpenter-logs-pending-pods.sh`
- **Tags**: `Kubernetes`, `Karpenter`, `correlation`, `logs`, `access:read-only`, `data:logs`
- **Reads**: `CONTEXT`, `KARPENTER_NAMESPACE`
- **Writes**: `karpenter_correlation_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


## Monitor

Measures Karpenter autoscaling health using NodePool or NodeClaim conditions, Pending capacity signals, and stuck NodeClaims. Produces a value between 0 and 1.

- **Robot file**: `sli.robot`
- **Score range**: `0.0` (failing) to `1.0` (healthy)
- **Aggregation**: arithmetic mean of the sub-checks below
- **Recommended interval**: `180s`

### Sub-checks

#### Measure Karpenter Autoscaling Health Score for Cluster `${CONTEXT}`

Runs lightweight kubectl checks and averages binary dimension scores into a single 0 to 1 metric.

- **Robot task name**: <code>Measure Karpenter Autoscaling Health Score for Cluster `${CONTEXT}`</code>
- **Sub-metric name**: `nodepool_nodeclaim_conditions`
- **Underlying script**: `sli-karpenter-autoscaling-score.sh`
- **Tags**: `access:read-only`, `data:config`
- **Reads**: `CONTEXT`


## Inputs

| Name | Type | Description | Default | Required |
|---|---|---|---|---|
| `CONTEXT` | string | Kubernetes context name for the target cluster. | — | yes |
| `KARPENTER_NAMESPACE` | string | Namespace where the Karpenter controller runs (for log tasks). | `karpenter` | no |
| `KUBERNETES_DISTRIBUTION_BINARY` | string | kubectl-compatible CLI binary. | `kubectl` | no |
| `RW_LOOKBACK_WINDOW` | string | Lookback window for logs and recent transitions. | `30m` | no |
| `KARPENTER_LOG_ERROR_THRESHOLD` | string | Minimum matching controller log lines before raising an issue. | `1` | no |
| `STUCK_NODECLAIM_THRESHOLD_MINUTES` | string | Minutes after which a non-ready NodeClaim is considered stale. | `30` | no |
| `KARPENTER_LOG_MAX_LINES` | string | Maximum tail lines per controller pod for log tasks. | `500` | no |
| `SLI_PENDING_POD_MAX` | string | Maximum Pending pods with capacity-like messages before SLI fails the pending dimension. | `5` | no |

## Secrets

_No secrets imported in Robot source._

## Outputs

- Monitor health score (`0.0`–`1.0`) pushed by `sli.robot`
- `karpenter_nodepool_nodeclaim_issues.json`
- `karpenter_pending_workload_issues.json`
- `karpenter_controller_log_issues.json`
- `karpenter_nodeclass_issues.json`
- `karpenter_stuck_nodeclaim_issues.json`
- `karpenter_correlation_issues.json`

## How to invoke

### Preferred: Robot Framework runner (`ro`)

```bash
cd codebundles/k8s-karpenter-autoscaling-health
export CONTEXT=...
export KARPENTER_NAMESPACE=...
export KUBERNETES_DISTRIBUTION_BINARY=...
export RW_LOOKBACK_WINDOW=...
export KARPENTER_LOG_ERROR_THRESHOLD=...
export STUCK_NODECLAIM_THRESHOLD_MINUTES=...
ro runbook.robot
```

### Standalone scripts (no Robot)


Set the input variables above, then run the matching script:

```bash
cd codebundles/k8s-karpenter-autoscaling-health
export CONTEXT=...
export KARPENTER_NAMESPACE=...
export KUBERNETES_DISTRIBUTION_BINARY=...
export RW_LOOKBACK_WINDOW=...
bash check-karpenter-nodeclass-conditions.sh
bash check-karpenter-nodepool-nodeclaim-status.sh
bash check-pending-provisioning-workloads.sh
bash check-stuck-nodeclaims.sh
bash correlate-karpenter-logs-pending-pods.sh
bash scan-karpenter-controller-logs.sh
bash sli-karpenter-autoscaling-score.sh
```

## Source files

- `runbook.robot` — orchestrates tools and raises issues
- `sli.robot` — monitor scoring (`sli.robot` runtime file)
- `check-karpenter-nodeclass-conditions.sh` — Bash helper script `check-karpenter-nodeclass-conditions.sh`.
- `check-karpenter-nodepool-nodeclaim-status.sh` — Bash helper script `check-karpenter-nodepool-nodeclaim-status.sh`.
- `check-pending-provisioning-workloads.sh` — Bash helper script `check-pending-provisioning-workloads.sh`.
- `check-stuck-nodeclaims.sh` — Bash helper script `check-stuck-nodeclaims.sh`.
- `correlate-karpenter-logs-pending-pods.sh` — Bash helper script `correlate-karpenter-logs-pending-pods.sh`.
- `scan-karpenter-controller-logs.sh` — Bash helper script `scan-karpenter-controller-logs.sh`.
- `sli-karpenter-autoscaling-score.sh` — Bash helper script `sli-karpenter-autoscaling-score.sh`.
