---
name: k8s-argocd-helm-health
kind: skill-template
description: This codebundle runs a series of tasks to identify potential helm release issues related to ArgoCD managed Helm objects. Use when triaging or monitoring Kubernetes, AKS, EKS workloads with skill te...
runtime:
  runbook: runbook.robot
  runner: ro
platforms: [Kubernetes, AKS, EKS, GKE, OpenShift, ArgoCD]
resource_types: [kubernetes_resource]
access: read-only
---

# Kubernetes ArgoCD HelmRelease TaskSet

## Summary

This codebundle is used to help measure and troubleshoot the health of an ArgoCD managed Helm deployments.

See [README.md](README.md) for additional context.

## Tools

### Fetch all available ArgoCD Helm releases in namespace `${NAMESPACE}`

List all ArgoCD helm releases that are visible to the kubeconfig.

- **Robot task name**: <code>Fetch all available ArgoCD Helm releases in namespace `${NAMESPACE}`</code>
- **Robot file**: `runbook.robot`
- **Tags**: `argocd`, `helmrelease`, `available`, `list`, `health`, `data:config`
- **Reads**: `CONTEXT`, `KUBERNETES_DISTRIBUTION_BINARY`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Fetch Installed ArgoCD Helm release versions in namespace `${NAMESPACE}`

Fetch Installed ArgoCD Helm release Versions.

- **Robot task name**: <code>Fetch Installed ArgoCD Helm release versions in namespace `${NAMESPACE}`</code>
- **Robot file**: `runbook.robot`
- **Tags**: `argocd`, `helmrelease`, `version`, `state`, `data:config`
- **Reads**: `CONTEXT`, `KUBERNETES_DISTRIBUTION_BINARY`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


## Inputs

| Name | Type | Description | Default | Required |
|---|---|---|---|---|
| `DISTRIBUTION` | string | Which distribution of Kubernetes to use for operations, such as: Kubernetes, OpenShift, etc. | `Kubernetes` | no |
| `KUBERNETES_DISTRIBUTION_BINARY` | string | Which binary to use for Kubernetes CLI commands. | `kubectl` | no |
| `CONTEXT` | string | Which Kubernetes context to operate within. | `default` | no |

## Secrets

_No secrets imported in Robot source._

## Outputs

_See Robot run output and platform report artifacts._

## How to invoke

### Preferred: Robot Framework runner (`ro`)

```bash
cd codebundles/k8s-argocd-helm-health
export DISTRIBUTION=...
export KUBERNETES_DISTRIBUTION_BINARY=...
export CONTEXT=...
ro runbook.robot
```

### Standalone scripts (no Robot)


_No standalone shell scripts in this bundle._

## Source files

- `runbook.robot` — orchestrates tools and raises issues
