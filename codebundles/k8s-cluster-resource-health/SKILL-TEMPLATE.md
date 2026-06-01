---
name: k8s-cluster-resource-health
kind: skill-template
description: Identify resource constraints or issues in a cluster. Use when triaging or monitoring Kubernetes, AKS, EKS workloads with skill template `k8s-cluster-resource-health`.
runtime:
  runbook: runbook.robot
  monitor: sli.robot
  runner: ro
platforms: [Kubernetes, AKS, EKS, GKE, OpenShift]
resource_types: [kubernetes_resource]
access: read-only
---

# Kubernetes Cluster Resource Health

## Summary

The Service Level Indicator will count the amount of nodes that are over 90% active utilization according to `kubectl top nodes` Create a report of all nodes that are above 90% utilization.

See [README.md](README.md) for additional context.

## Tools

### Identify High Utilization Nodes for Cluster `${CONTEXT}`

Identify nodes with high utilization . Requires jq.

- **Robot task name**: <code>Identify High Utilization Nodes for Cluster `${CONTEXT}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `get_high_use_nodes.sh`
- **Tags**: `cluster`, `resources`, `cpu`, `memory`, `utilization`, `saturation`, `exhaustion`, `starvation`, `access:read-only`, `data:config`
- **Reads**: `CONTEXT`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Identify Pods Causing High Node Utilization in Cluster `${CONTEXT}`

Identify nodes with high utilization and match to pods that are significantly above their resource request configuration. Requires jq.

- **Robot task name**: <code>Identify Pods Causing High Node Utilization in Cluster `${CONTEXT}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `pods_impacting_high_use_nodes.sh`
- **Tags**: `pods`, `resources`, `requests`, `utilization`, `cpu`, `memory`, `exhaustion`, `access:read-only`, `data:config`
- **Reads**: `CONTEXT`
- **Writes**: `pods_exceeding_requests.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Identify Pods with Resource Limits Exceeding Node Capacity in Cluster `${CONTEXT}`

Identify any Pods in the Cluster `${CONTEXT}` with resource limits (CPU or Memory) larger than the Node's allocatable capacity.

- **Robot task name**: <code>Identify Pods with Resource Limits Exceeding Node Capacity in Cluster `${CONTEXT}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `overlimit_check.sh`
- **Tags**: `nodes`, `limits`, `utilization`, `saturation`, `exhaustion`, `access:read-only`, `data:config`
- **Reads**: `CONTEXT`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


## Monitor

Counts the number of nodes above 90% CPU or Memory Utilization from kubectl top.

- **Robot file**: `sli.robot`
- **Score range**: `0.0` (failing) to `1.0` (healthy)
- **Aggregation**: arithmetic mean of the sub-checks below
- **Recommended interval**: `180s`

### Sub-checks

#### Identify High Utilization Nodes for Cluster `${CONTEXT}`

Fetch utilization of each node and raise issue if CPU or Memory is above 90% utilization . Requires jq. Requires get/list of nodes in "metrics.k8s.io"

- **Robot task name**: <code>Identify High Utilization Nodes for Cluster `${CONTEXT}`</code>
- **Sub-metric name**: `node_utilization`
- **Underlying script**: `get_high_use_nodes.sh`
- **Tags**: `Cluster`, `Resources`, `CPU`, `Memory`, `Utilization`, `Saturation`, `Exhaustion`, `Starvation`, `data:config`
- **Reads**: —


#### Identify Pods with Resource Limits Exceeding Node Capacity in Cluster `${CONTEXT}`

Identify any Pods in the Cluster `${CONTEXT}` with resource limits (CPU or Memory) larger than the Node's allocatable capacity.

- **Robot task name**: <code>Identify Pods with Resource Limits Exceeding Node Capacity in Cluster `${CONTEXT}`</code>
- **Sub-metric name**: `resource_limits`
- **Underlying script**: `overlimit_check.sh`
- **Tags**: `nodes`, `limits`, `utilization`, `saturation`, `exhaustion`, `access:read-only`, `data:config`
- **Reads**: `CONTEXT`


## Inputs

| Name | Type | Description | Default | Required |
|---|---|---|---|---|
| `KUBERNETES_DISTRIBUTION_BINARY` | string | Which binary to use for Kubernetes CLI commands. | `kubectl` | no |
| `CONTEXT` | string | Which Kubernetes context to operate within. | `default` | no |
| `MAX_LIMIT_PERCENTAGE` | string | The maximum % that a limit can be in regards to the underlying node capacity. | `90` | no |
| `MEM_USAGE_MIN` | string | The minimum value (in MB) in which to evaluate requests vs usage. Usage below this value are not evaluated. | `100` | no |
| `CPU_USAGE_MIN` | string | The minimum value (in millicores) in which to evaluate requests vs usage. Usage below this value are not evaluated. | `100` | no |

## Secrets

_No secrets imported in Robot source._

## Outputs

- Monitor health score (`0.0`–`1.0`) pushed by `sli.robot`
- `pods_exceeding_requests.json`

## How to invoke

### Preferred: Robot Framework runner (`ro`)

```bash
cd codebundles/k8s-cluster-resource-health
export KUBERNETES_DISTRIBUTION_BINARY=...
export CONTEXT=...
export MAX_LIMIT_PERCENTAGE=...
export MEM_USAGE_MIN=...
export CPU_USAGE_MIN=...
ro runbook.robot
```

### Standalone scripts (no Robot)


Set the input variables above, then run the matching script:

```bash
cd codebundles/k8s-cluster-resource-health
export KUBERNETES_DISTRIBUTION_BINARY=...
export CONTEXT=...
export MAX_LIMIT_PERCENTAGE=...
export MEM_USAGE_MIN=...
bash get_high_use_nodes.sh
bash overlimit_check.sh
bash pods_impacting_high_use_nodes.sh
```

## Source files

- `runbook.robot` — orchestrates tools and raises issues
- `sli.robot` — monitor scoring (`sli.robot` runtime file)
- `get_high_use_nodes.sh` — Bash helper script `get_high_use_nodes.sh`.
- `overlimit_check.sh` — Bash helper script `overlimit_check.sh`.
- `pods_impacting_high_use_nodes.sh` — Bash helper script `pods_impacting_high_use_nodes.sh`.
