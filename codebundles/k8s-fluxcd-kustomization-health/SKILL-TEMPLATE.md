---
name: k8s-fluxcd-kustomization-health
kind: skill-template
description: This codebundle runs a series of tasks to identify potential Kustomization issues related to Flux managed... Use when triaging or monitoring Kubernetes, AKS, EKS workloads with skill template `k8s-...
runtime:
  runbook: runbook.robot
  monitor: sli.robot
  runner: ro
platforms: [Kubernetes, AKS, EKS, GKE, OpenShift, FluxCD]
resource_types: [kubernetes_resource]
access: read-only
---

# Kubernetes FluxCD Kustomization TaskSet

## Summary

The `k8s-fluxcd-kustomizations-health` codebundle checks for Kustomization resources within the Kubernetes cluster to surface up potential issues.

See [README.md](README.md) for additional context.

## Tools

### List All FluxCD Kustomization objects in Namespace `${NAMESPACE}` in Cluster `${CONTEXT}`

List all FluxCD kustomization objects.

- **Robot task name**: <code>List All FluxCD Kustomization objects in Namespace `${NAMESPACE}` in Cluster `${CONTEXT}`</code>
- **Robot file**: `runbook.robot`
- **Tags**: `access:read-only`, `FluxCD`, `Kustomization`, `Available`, `List`, `${NAMESPACE}`, `data:config`
- **Reads**: `CONTEXT`, `KUBERNETES_DISTRIBUTION_BINARY`, `NAMESPACE`, `RESOURCE_NAME`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### List Suspended FluxCD Kustomization objects in Namespace `${NAMESPACE}` in Cluster `${CONTEXT}`

List Suspended FluxCD kustomization objects.

- **Robot task name**: <code>List Suspended FluxCD Kustomization objects in Namespace `${NAMESPACE}` in Cluster `${CONTEXT}`</code>
- **Robot file**: `runbook.robot`
- **Tags**: `access:read-only`, `FluxCD`, `Kustomization`, `Suspended`, `List`, `data:config`
- **Reads**: `CONTEXT`, `KUBERNETES_DISTRIBUTION_BINARY`, `NAMESPACE`, `RESOURCE_NAME`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### List Unready FluxCD Kustomizations in Namespace `${NAMESPACE}` in Cluster `${CONTEXT}`

List all Kustomizations that are not found in a ready state in namespace.

- **Robot task name**: <code>List Unready FluxCD Kustomizations in Namespace `${NAMESPACE}` in Cluster `${CONTEXT}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `workload_next_steps.sh`
- **Tags**: `access:read-only`, `FluxCD`, `Kustomization`, `Versions`, `${NAMESPACE}`, `data:config`
- **Reads**: `CONTEXT`, `KUBERNETES_DISTRIBUTION_BINARY`, `NAMESPACE`, `RESOURCE_NAME`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


## Monitor

This codebundle checks for unhealthy or suspended FluxCD Kustomization objects.

- **Robot file**: `sli.robot`
- **Score range**: `0.0` (failing) to `1.0` (healthy)
- **Aggregation**: arithmetic mean of the sub-checks below
- **Recommended interval**: `180s`

### Sub-checks

#### List Suspended FluxCD Kustomization objects in Namespace `${NAMESPACE}` in Cluster `${CONTEXT}`

List Suspended FluxCD kustomization objects.

- **Robot task name**: <code>List Suspended FluxCD Kustomization objects in Namespace `${NAMESPACE}` in Cluster `${CONTEXT}`</code>
- **Sub-metric name**: `suspended_kustomizations`
- **Tags**: `access:read-only`, `FluxCD`, `Kustomization`, `Suspended`, `List`, `data:config`
- **Reads**: `CONTEXT`, `KUBERNETES_DISTRIBUTION_BINARY`, `NAMESPACE`, `RESOURCE_NAME`


#### List Unready FluxCD Kustomizations in Namespace `${NAMESPACE}` in Cluster `${CONTEXT}`

List all Kustomizations that are not found in a ready state in namespace.

- **Robot task name**: <code>List Unready FluxCD Kustomizations in Namespace `${NAMESPACE}` in Cluster `${CONTEXT}`</code>
- **Sub-metric name**: `unready_kustomizations`
- **Tags**: `access:read-only`, `FluxCD`, `Kustomization`, `Versions`, `${NAMESPACE}`, `data:config`
- **Reads**: `CONTEXT`, `KUBERNETES_DISTRIBUTION_BINARY`, `NAMESPACE`, `RESOURCE_NAME`


## Inputs

| Name | Type | Description | Default | Required |
|---|---|---|---|---|
| `DISTRIBUTION` | string | Which distribution of Kubernetes to use for operations, such as: Kubernetes, OpenShift, etc. | `Kubernetes` | no |
| `KUBERNETES_DISTRIBUTION_BINARY` | string | Which binary to use for Kubernetes CLI commands. | `kubectl` | no |
| `NAMESPACE` | string | The name of the Kubernetes namespace to scope actions and searching to. | `default` | no |
| `RESOURCE_NAME` | string | The short or long name of the Kubernetes kustomizations resource to search for. These might vary by Kustomize controller implementation, and are best to use full crd name. | `kustomizations` | no |
| `CONTEXT` | string | Which Kubernetes context to operate within. | `default` | no |

## Secrets

_No secrets imported in Robot source._

## Outputs

- Monitor health score (`0.0`–`1.0`) pushed by `sli.robot`

## How to invoke

### Preferred: Robot Framework runner (`ro`)

```bash
cd codebundles/k8s-fluxcd-kustomization-health
export DISTRIBUTION=...
export KUBERNETES_DISTRIBUTION_BINARY=...
export NAMESPACE=...
export RESOURCE_NAME=...
export CONTEXT=...
ro runbook.robot
```

### Standalone scripts (no Robot)


Set the input variables above, then run the matching script:

```bash
cd codebundles/k8s-fluxcd-kustomization-health
export DISTRIBUTION=...
export KUBERNETES_DISTRIBUTION_BINARY=...
export NAMESPACE=...
export RESOURCE_NAME=...
bash workload_next_steps.sh
```

## Source files

- `runbook.robot` — orchestrates tools and raises issues
- `sli.robot` — monitor scoring (`sli.robot` runtime file)
- `workload_next_steps.sh` — Bash helper script `workload_next_steps.sh`.
