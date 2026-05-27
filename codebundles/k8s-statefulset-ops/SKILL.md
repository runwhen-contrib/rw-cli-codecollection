---
name: k8s-statefulset-ops
description: Perform operational tasks for a Kubernetes StatefulSet. Use when triaging or monitoring Kubernetes, AKS, EKS workloads with skill template `k8s-statefulset-ops`.
runtime:
  runbook: runbook.robot
  runner: ro
platforms: [Kubernetes, AKS, EKS, GKE, OpenShift]
resource_types: [statefulset]
access: read-only
---

# Kubernetes StatefulSet Operations

## Summary

This codebundle provides StatefulSet-scoped operational tasks so operators can restart workloads, recycle pods, roll back, scale replicas, tune HPA bounds, and adjust CPU or memory resources—similar to `k8s-deployment-ops`, but for the StatefulSet API.

See [README.md](README.md) for additional context.

## Tools

### Restart StatefulSet `${STATEFULSET_NAME}` in Namespace `${NAMESPACE}`

Perform a rollout restart on the StatefulSet

- **Robot task name**: <code>Restart StatefulSet `${STATEFULSET_NAME}` in Namespace `${NAMESPACE}`</code>
- **Robot file**: `runbook.robot`
- **Tags**: —
- **Reads**: `CONTEXT`, `KUBERNETES_DISTRIBUTION_BINARY`, `NAMESPACE`, `STATEFULSET_NAME`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Force Delete Pods for StatefulSet `${STATEFULSET_NAME}` in Namespace `${NAMESPACE}`

Force delete all pods related to the StatefulSet using pod template labels

- **Robot task name**: <code>Force Delete Pods for StatefulSet `${STATEFULSET_NAME}` in Namespace `${NAMESPACE}`</code>
- **Robot file**: `runbook.robot`
- **Tags**: —
- **Reads**: `CONTEXT`, `KUBERNETES_DISTRIBUTION_BINARY`, `NAMESPACE`, `STATEFULSET_NAME`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Rollback StatefulSet `${STATEFULSET_NAME}` in Namespace `${NAMESPACE}` to Previous Version

Perform a rollback to a known functional version

- **Robot task name**: <code>Rollback StatefulSet `${STATEFULSET_NAME}` in Namespace `${NAMESPACE}` to Previous Version</code>
- **Robot file**: `runbook.robot`
- **Tags**: —
- **Reads**: `CONTEXT`, `KUBERNETES_DISTRIBUTION_BINARY`, `NAMESPACE`, `STATEFULSET_NAME`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Scale Down StatefulSet `${STATEFULSET_NAME}` in Namespace `${NAMESPACE}`

Stops (or nearly stops) all running pods in a StatefulSet to immediately halt a failing or runaway service.

- **Robot task name**: <code>Scale Down StatefulSet `${STATEFULSET_NAME}` in Namespace `${NAMESPACE}`</code>
- **Robot file**: `runbook.robot`
- **Tags**: —
- **Reads**: `ALLOW_SCALE_TO_ZERO`, `CONTEXT`, `KUBERNETES_DISTRIBUTION_BINARY`, `NAMESPACE`, `STATEFULSET_NAME`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Scale Up StatefulSet `${STATEFULSET_NAME}` in Namespace `${NAMESPACE}` by ${SCALE_UP_FACTOR}x

Increase StatefulSet replicas by multiplying current count by SCALE_UP_FACTOR (capped by MAX_REPLICAS).

- **Robot task name**: <code>Scale Up StatefulSet `${STATEFULSET_NAME}` in Namespace `${NAMESPACE}` by ${SCALE_UP_FACTOR}x</code>
- **Robot file**: `runbook.robot`
- **Tags**: —
- **Reads**: `CONTEXT`, `KUBERNETES_DISTRIBUTION_BINARY`, `MAX_REPLICAS`, `NAMESPACE`, `SCALE_UP_FACTOR`, `STATEFULSET_NAME`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Scale Up HPA for StatefulSet `${STATEFULSET_NAME}` in Namespace `${NAMESPACE}` by ${HPA_SCALE_FACTOR}x

Increase HPA min and max replicas by a scaling factor

- **Robot task name**: <code>Scale Up HPA for StatefulSet `${STATEFULSET_NAME}` in Namespace `${NAMESPACE}` by ${HPA_SCALE_FACTOR}x</code>
- **Robot file**: `runbook.robot`
- **Tags**: —
- **Reads**: `CONTEXT`, `HPA_MAX_REPLICAS`, `HPA_SCALE_FACTOR`, `KUBERNETES_DISTRIBUTION_BINARY`, `NAMESPACE`, `STATEFULSET_NAME`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Scale Down HPA for StatefulSet `${STATEFULSET_NAME}` in Namespace `${NAMESPACE}` to Min ${HPA_MIN_REPLICAS}

Decrease HPA min and max replicas to specified minimum values or scale down by factor

- **Robot task name**: <code>Scale Down HPA for StatefulSet `${STATEFULSET_NAME}` in Namespace `${NAMESPACE}` to Min ${HPA_MIN_REPLICAS}</code>
- **Robot file**: `runbook.robot`
- **Tags**: —
- **Reads**: `CONTEXT`, `HPA_MIN_REPLICAS`, `KUBERNETES_DISTRIBUTION_BINARY`, `NAMESPACE`, `STATEFULSET_NAME`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Increase CPU Resources for StatefulSet `${STATEFULSET_NAME}` in Namespace `${NAMESPACE}`

Intelligently increases CPU resources for a StatefulSet based on VPA recommendations, HPA presence, or doubles current values. Does not apply if GitOps-managed or HPA exists.

- **Robot task name**: <code>Increase CPU Resources for StatefulSet `${STATEFULSET_NAME}` in Namespace `${NAMESPACE}`</code>
- **Robot file**: `runbook.robot`
- **Tags**: —
- **Reads**: `CONTEXT`, `KUBERNETES_DISTRIBUTION_BINARY`, `NAMESPACE`, `STATEFULSET_NAME`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Increase Memory Resources for StatefulSet `${STATEFULSET_NAME}` in Namespace `${NAMESPACE}`

Intelligently increases memory resources for a StatefulSet based on VPA recommendations, HPA presence, or doubles current values. Does not apply if GitOps-managed or HPA exists.

- **Robot task name**: <code>Increase Memory Resources for StatefulSet `${STATEFULSET_NAME}` in Namespace `${NAMESPACE}`</code>
- **Robot file**: `runbook.robot`
- **Tags**: —
- **Reads**: `CONTEXT`, `KUBERNETES_DISTRIBUTION_BINARY`, `NAMESPACE`, `STATEFULSET_NAME`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Decrease CPU Resources for StatefulSet `${STATEFULSET_NAME}` in Namespace `${NAMESPACE}`

Intelligently decreases CPU resources for a StatefulSet by dividing current values by scale down factor. Does not apply if GitOps-managed or HPA exists.

- **Robot task name**: <code>Decrease CPU Resources for StatefulSet `${STATEFULSET_NAME}` in Namespace `${NAMESPACE}`</code>
- **Robot file**: `runbook.robot`
- **Tags**: —
- **Reads**: `CONTEXT`, `KUBERNETES_DISTRIBUTION_BINARY`, `NAMESPACE`, `RESOURCE_SCALE_DOWN_FACTOR`, `STATEFULSET_NAME`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Decrease Memory Resources for StatefulSet `${STATEFULSET_NAME}` in Namespace `${NAMESPACE}`

Intelligently decreases memory resources for a StatefulSet by dividing current values by scale down factor. Does not apply if GitOps-managed or HPA exists.

- **Robot task name**: <code>Decrease Memory Resources for StatefulSet `${STATEFULSET_NAME}` in Namespace `${NAMESPACE}`</code>
- **Robot file**: `runbook.robot`
- **Tags**: —
- **Reads**: `CONTEXT`, `KUBERNETES_DISTRIBUTION_BINARY`, `NAMESPACE`, `RESOURCE_SCALE_DOWN_FACTOR`, `STATEFULSET_NAME`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


## Inputs

| Name | Type | Description | Default | Required |
|---|---|---|---|---|
| `STATEFULSET_NAME` | string | Used to target the StatefulSet for queries and filtering events. | — | yes |
| `NAMESPACE` | string | The name of the Kubernetes namespace to scope actions and searching to. | — | yes |
| `CONTEXT` | string | Which Kubernetes context to operate within. | — | yes |
| `KUBERNETES_DISTRIBUTION_BINARY` | string | Which binary to use for Kubernetes CLI commands. | `kubectl` | no |
| `SCALE_UP_FACTOR` | string | The multiple by which to increase replica count. For example, a StatefulSet with 2 pods and a scale up factor of 2 will target 4 pods. | `2` | no |
| `MAX_REPLICAS` | string | The Max replicas for any scaleup activity. | `10` | no |
| `ALLOW_SCALE_TO_ZERO` | string | Permit StatefulSets to scale to 0. | `false` | no |
| `HPA_SCALE_FACTOR` | string | The multiple by which to scale HPA min/max replicas. | `2` | no |
| `HPA_MAX_REPLICAS` | string | The maximum replicas allowed for HPA max value during scale up operations. | `20` | no |
| `HPA_MIN_REPLICAS` | string | The minimum replicas to set for HPA during scale down operations. | `1` | no |
| `RESOURCE_SCALE_DOWN_FACTOR` | string | The factor by which to divide CPU/memory resources when scaling down (e.g., 2 means divide by 2). | `2` | no |

## Secrets

_No secrets imported in Robot source._

## Outputs

_See Robot run output and platform report artifacts._

## How to invoke

### Preferred: Robot Framework runner (`ro`)

```bash
cd codebundles/k8s-statefulset-ops
export STATEFULSET_NAME=...
export NAMESPACE=...
export CONTEXT=...
export KUBERNETES_DISTRIBUTION_BINARY=...
export SCALE_UP_FACTOR=...
export MAX_REPLICAS=...
ro runbook.robot
```

### Standalone scripts (no Robot)


_No standalone shell scripts in this bundle._

## Source files

- `runbook.robot` — orchestrates tools and raises issues
