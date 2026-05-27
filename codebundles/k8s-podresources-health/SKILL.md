---
name: k8s-podresources-health
description: Inspects the resources provisioned for a given set of pods and raises issues or recommendations as necessary. Use when triaging or monitoring Kubernetes, AKS, EKS workloads with skill template `k8s...
runtime:
  runbook: runbook.robot
  runner: ro
platforms: [Kubernetes, AKS, EKS, GKE, OpenShift]
resource_types: [pod]
access: read-only
---

# Kubernetes Pod Resources Health

## Summary

Inspects the resources provisioned for a given set of pods and raises issues or recommendations as necessary.

See [README.md](README.md) for additional context.

## Tools

### Show Pods Without Resource Limit or Resource Requests Set in Namespace `${NAMESPACE}`

Scans a list of pods in a namespace using labels as a selector and checks if their resources are set.

- **Robot task name**: <code>Show Pods Without Resource Limit or Resource Requests Set in Namespace `${NAMESPACE}`</code>
- **Robot file**: `runbook.robot`
- **Tags**: —
- **Reads**: `CONTEXT`, `KUBERNETES_DISTRIBUTION_BINARY`, `LABELS`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Check Pod Resource Utilization with Top in Namespace `${NAMESPACE}`

Performs and a top command on list of labeled workloads to check pod resources.

- **Robot task name**: <code>Check Pod Resource Utilization with Top in Namespace `${NAMESPACE}`</code>
- **Robot file**: `runbook.robot`
- **Tags**: `access:read-only`, `top`, `resources`, `utilization`, `pods`, `workloads`, `cpu`, `memory`, `allocation`, `labeled`, `${NAMESPACE}`, `data:config`
- **Reads**: `CONTEXT`, `KUBERNETES_DISTRIBUTION_BINARY`, `LABELS`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Identify VPA Pod Resource Recommendations in Namespace `${NAMESPACE}`

Queries the namespace for any Vertical Pod Autoscaler resource recommendations.

- **Robot task name**: <code>Identify VPA Pod Resource Recommendations in Namespace `${NAMESPACE}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `vpa_recommendations.sh`
- **Tags**: `access:read-only`, `recommendation`, `resources`, `utilization`, `pods`, `cpu`, `memory`, `allocation`, `vpa`, `${NAMESPACE}`, `data:config`
- **Reads**: `NAMESPACE`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Identify Overutilized Pods in Namespace `${NAMESPACE}`

Scans the namespace for pods that are over utilizing resources or may be experiencing resource problems like oomkills or restarts.

- **Robot task name**: <code>Identify Overutilized Pods in Namespace `${NAMESPACE}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `find_resource_owners.sh`
- **Tags**: `access:read-only`, `overutilized`, `resources`, `utilization`, `pods`, `cpu`, `memory`, `allocation`, `${NAMESPACE}`, `oomkill`, `restarts`, `data:config`
- **Reads**: `CONTEXT`
- **Writes**: `overutilized_pods.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


## Inputs

| Name | Type | Description | Default | Required |
|---|---|---|---|---|
| `CONTEXT` | string | Which Kubernetes context to operate within. | `''` | no |
| `LABELS` | string | The metadata labels to use when selecting the objects to measure as running. | `''` | no |
| `KUBERNETES_DISTRIBUTION_BINARY` | string | Which binary to use for Kubernetes CLI commands. | `kubectl` | no |
| `UTILIZATION_THRESHOLD` | string | The resource usage threshold at which to identify issues. | `95` | no |
| `DEFAULT_INCREASE` | string | The percentage increase for resource recommendations. | `25` | no |
| `RESTART_AGE` | string | The age (in minutes) to consider when looking for container restarts. | `10` | no |

## Secrets

_No secrets imported in Robot source._

## Outputs

- `overutilized_pods.json`

## How to invoke

### Preferred: Robot Framework runner (`ro`)

```bash
cd codebundles/k8s-podresources-health
export CONTEXT=...
export LABELS=...
export KUBERNETES_DISTRIBUTION_BINARY=...
export UTILIZATION_THRESHOLD=...
export DEFAULT_INCREASE=...
export RESTART_AGE=...
ro runbook.robot
```

### Standalone scripts (no Robot)


Set the input variables above, then run the matching script:

```bash
cd codebundles/k8s-podresources-health
export CONTEXT=...
export LABELS=...
export KUBERNETES_DISTRIBUTION_BINARY=...
export UTILIZATION_THRESHOLD=...
bash find_resource_owners.sh
bash identify_resource_contrained_pods.sh
bash vpa_recommendations.sh
```

## Source files

- `runbook.robot` — orchestrates tools and raises issues
- `find_resource_owners.sh` — Bash helper script `find_resource_owners.sh`.
- `identify_resource_contrained_pods.sh` — Bash helper script `identify_resource_contrained_pods.sh`.
- `vpa_recommendations.sh` — Bash helper script `vpa_recommendations.sh`.
