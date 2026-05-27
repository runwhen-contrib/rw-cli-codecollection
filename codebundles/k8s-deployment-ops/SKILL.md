---
name: k8s-deployment-ops
description: Perform oprational tasks for a Kubernetes deployment. Use when triaging or monitoring Kubernetes, AKS, EKS workloads with skill template `k8s-deployment-ops`.
runtime:
  runbook: runbook.robot
  runner: ro
platforms: [Kubernetes, AKS, EKS, GKE, OpenShift]
resource_types: [deployment]
access: read-only
---

# Kubernetes Deployment Operations

## Summary

This codebundle provides a suite of operational tasks related to a deployment in Kubernetes clusters.

See [README.md](README.md) for additional context.

## Tools

### Restart Deployment `${DEPLOYMENT_NAME}` in Namespace `${NAMESPACE}`

Perform a rollout restart on the deployment

- **Robot task name**: <code>Restart Deployment `${DEPLOYMENT_NAME}` in Namespace `${NAMESPACE}`</code>
- **Robot file**: `runbook.robot`
- **Tags**: —
- **Reads**: `CONTEXT`, `DEPLOYMENT_NAME`, `KUBERNETES_DISTRIBUTION_BINARY`, `NAMESPACE`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Force Delete Pods in Deployment `${DEPLOYMENT_NAME}` in Namespace `${NAMESPACE}`

Force delete all pods related to the deployment

- **Robot task name**: <code>Force Delete Pods in Deployment `${DEPLOYMENT_NAME}` in Namespace `${NAMESPACE}`</code>
- **Robot file**: `runbook.robot`
- **Tags**: —
- **Reads**: `CONTEXT`, `DEPLOYMENT_NAME`, `KUBERNETES_DISTRIBUTION_BINARY`, `NAMESPACE`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Rollback Deployment `${DEPLOYMENT_NAME}` in Namespace `${NAMESPACE}` to Previous Version

Perform a rollback to a known functional version

- **Robot task name**: <code>Rollback Deployment `${DEPLOYMENT_NAME}` in Namespace `${NAMESPACE}` to Previous Version</code>
- **Robot file**: `runbook.robot`
- **Tags**: —
- **Reads**: `CONTEXT`, `DEPLOYMENT_NAME`, `KUBERNETES_DISTRIBUTION_BINARY`, `NAMESPACE`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Scale Down Deployment `${DEPLOYMENT_NAME}` in Namespace `${NAMESPACE}`

Stops (or nearly stops) all running pods in a deployment to immediately halt a failing or runaway service.

- **Robot task name**: <code>Scale Down Deployment `${DEPLOYMENT_NAME}` in Namespace `${NAMESPACE}`</code>
- **Robot file**: `runbook.robot`
- **Tags**: —
- **Reads**: `ALLOW_SCALE_TO_ZERO`, `CONTEXT`, `DEPLOYMENT_NAME`, `KUBERNETES_DISTRIBUTION_BINARY`, `NAMESPACE`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Scale Up Deployment `${DEPLOYMENT_NAME}` in Namespace `${NAMESPACE}` by ${SCALE_UP_FACTOR}x

Increase deployment replicas

- **Robot task name**: <code>Scale Up Deployment `${DEPLOYMENT_NAME}` in Namespace `${NAMESPACE}` by ${SCALE_UP_FACTOR}x</code>
- **Robot file**: `runbook.robot`
- **Tags**: —
- **Reads**: `CONTEXT`, `DEPLOYMENT_NAME`, `KUBERNETES_DISTRIBUTION_BINARY`, `MAX_REPLICAS`, `NAMESPACE`, `SCALE_UP_FACTOR`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Clean Up Stale ReplicaSets for Deployment `${DEPLOYMENT_NAME}` in Namespace `${NAMESPACE}`

Deletes all stale replicasets.

- **Robot task name**: <code>Clean Up Stale ReplicaSets for Deployment `${DEPLOYMENT_NAME}` in Namespace `${NAMESPACE}`</code>
- **Robot file**: `runbook.robot`
- **Tags**: —
- **Reads**: `CONTEXT`, `DEPLOYMENT_NAME`, `KUBERNETES_DISTRIBUTION_BINARY`, `NAMESPACE`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Scale Down Stale ReplicaSets for Deployment `${DEPLOYMENT_NAME}` in Namespace `${NAMESPACE}`

Finds any old/stale replicasets that still have active pods and scales them down.

- **Robot task name**: <code>Scale Down Stale ReplicaSets for Deployment `${DEPLOYMENT_NAME}` in Namespace `${NAMESPACE}`</code>
- **Robot file**: `runbook.robot`
- **Tags**: —
- **Reads**: `CONTEXT`, `DEPLOYMENT_NAME`, `KUBERNETES_DISTRIBUTION_BINARY`, `NAMESPACE`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Scale Up HPA for Deployment `${DEPLOYMENT_NAME}` in Namespace `${NAMESPACE}` by ${HPA_SCALE_FACTOR}x

Increase HPA min and max replicas by a scaling factor

- **Robot task name**: <code>Scale Up HPA for Deployment `${DEPLOYMENT_NAME}` in Namespace `${NAMESPACE}` by ${HPA_SCALE_FACTOR}x</code>
- **Robot file**: `runbook.robot`
- **Tags**: —
- **Reads**: `CONTEXT`, `DEPLOYMENT_NAME`, `HPA_MAX_REPLICAS`, `HPA_SCALE_FACTOR`, `KUBERNETES_DISTRIBUTION_BINARY`, `NAMESPACE`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Scale Down HPA for Deployment `${DEPLOYMENT_NAME}` in Namespace `${NAMESPACE}` to Min ${HPA_MIN_REPLICAS}

Decrease HPA min and max replicas to specified minimum values or scale down by factor

- **Robot task name**: <code>Scale Down HPA for Deployment `${DEPLOYMENT_NAME}` in Namespace `${NAMESPACE}` to Min ${HPA_MIN_REPLICAS}</code>
- **Robot file**: `runbook.robot`
- **Tags**: —
- **Reads**: `CONTEXT`, `DEPLOYMENT_NAME`, `HPA_MIN_REPLICAS`, `KUBERNETES_DISTRIBUTION_BINARY`, `NAMESPACE`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Increase CPU Resources for Deployment `${DEPLOYMENT_NAME}` in Namespace `${NAMESPACE}`

Intelligently increases CPU resources for a deployment based on VPA recommendations, HPA presence, or doubles current values. Does not apply if GitOps-managed or HPA exists.

- **Robot task name**: <code>Increase CPU Resources for Deployment `${DEPLOYMENT_NAME}` in Namespace `${NAMESPACE}`</code>
- **Robot file**: `runbook.robot`
- **Tags**: —
- **Reads**: `CONTEXT`, `DEPLOYMENT_NAME`, `KUBERNETES_DISTRIBUTION_BINARY`, `NAMESPACE`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Increase Memory Resources for Deployment `${DEPLOYMENT_NAME}` in Namespace `${NAMESPACE}`

Intelligently increases memory resources for a deployment based on VPA recommendations, HPA presence, or doubles current values. Does not apply if GitOps-managed or HPA exists.

- **Robot task name**: <code>Increase Memory Resources for Deployment `${DEPLOYMENT_NAME}` in Namespace `${NAMESPACE}`</code>
- **Robot file**: `runbook.robot`
- **Tags**: —
- **Reads**: `CONTEXT`, `DEPLOYMENT_NAME`, `KUBERNETES_DISTRIBUTION_BINARY`, `NAMESPACE`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Decrease CPU Resources for Deployment `${DEPLOYMENT_NAME}` in Namespace `${NAMESPACE}`

Intelligently decreases CPU resources for a deployment by dividing current values by scale down factor. Does not apply if GitOps-managed or HPA exists.

- **Robot task name**: <code>Decrease CPU Resources for Deployment `${DEPLOYMENT_NAME}` in Namespace `${NAMESPACE}`</code>
- **Robot file**: `runbook.robot`
- **Tags**: —
- **Reads**: `CONTEXT`, `DEPLOYMENT_NAME`, `KUBERNETES_DISTRIBUTION_BINARY`, `NAMESPACE`, `RESOURCE_SCALE_DOWN_FACTOR`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Decrease Memory Resources for Deployment `${DEPLOYMENT_NAME}` in Namespace `${NAMESPACE}`

Intelligently decreases memory resources for a deployment by dividing current values by scale down factor. Does not apply if GitOps-managed or HPA exists.

- **Robot task name**: <code>Decrease Memory Resources for Deployment `${DEPLOYMENT_NAME}` in Namespace `${NAMESPACE}`</code>
- **Robot file**: `runbook.robot`
- **Tags**: —
- **Reads**: `CONTEXT`, `DEPLOYMENT_NAME`, `KUBERNETES_DISTRIBUTION_BINARY`, `NAMESPACE`, `RESOURCE_SCALE_DOWN_FACTOR`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


## Inputs

| Name | Type | Description | Default | Required |
|---|---|---|---|---|
| `DEPLOYMENT_NAME` | string | Used to target the resource for queries and filtering events. | — | yes |
| `NAMESPACE` | string | The name of the Kubernetes namespace to scope actions and searching to. | — | yes |
| `CONTEXT` | string | Which Kubernetes context to operate within. | — | yes |
| `KUBERNETES_DISTRIBUTION_BINARY` | string | Which binary to use for Kubernetes CLI commands. | `kubectl` | no |
| `SCALE_UP_FACTOR` | string | The multiple in which to increase the total amount of pods. For example, a deployment with 2 pods and a scale up factor of 2 will result in 4 pods. | `2` | no |
| `MAX_REPLICAS` | string | The Max replicas for any scaleup activity. | `10` | no |
| `ALLOW_SCALE_TO_ZERO` | string | Permit deployments to scale to 0. | `false` | no |
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
cd codebundles/k8s-deployment-ops
export DEPLOYMENT_NAME=...
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
