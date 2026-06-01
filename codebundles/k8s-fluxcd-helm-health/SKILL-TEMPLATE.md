---
name: k8s-fluxcd-helm-health
kind: skill-template
description: This codebundle runs a series of tasks to identify potential helm release issues related to Flux managed Helm objects. Use when triaging or monitoring Kubernetes, AKS, EKS workloads with skill temp...
runtime:
  runbook: runbook.robot
  runner: ro
platforms: [Kubernetes, AKS, EKS, GKE, OpenShift, FluxCD]
resource_types: [kubernetes_resource]
access: read-only
---

# Kubernetes FluxCD HelmRelease TaskSet

## Summary

The `k8s-fluxcd-helm-health` codebundle checks for helm related resources within the Kubernetes cluster to surface up potential issues.

See [README.md](README.md) for additional context.

## Tools

### List all available FluxCD Helmreleases in Namespace `${NAMESPACE}`

List all FluxCD helmreleases that are visible to the kubeconfig.

- **Robot task name**: <code>List all available FluxCD Helmreleases in Namespace `${NAMESPACE}`</code>
- **Robot file**: `runbook.robot`
- **Tags**: `FluxCD`, `Helmrelease`, `Available`, `List`, `${NAMESPACE}`, `data:config`
- **Reads**: `CONTEXT`, `KUBERNETES_DISTRIBUTION_BINARY`, `NAMESPACE`, `RESOURCE_NAME`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Fetch Installed FluxCD Helmrelease Versions in Namespace `${NAMESPACE}`

List helmreleases and  the last attempted software version and the current running version.

- **Robot task name**: <code>Fetch Installed FluxCD Helmrelease Versions in Namespace `${NAMESPACE}`</code>
- **Robot file**: `runbook.robot`
- **Tags**: `FluxCD`, `Helmrelease`, `Versions`, `${NAMESPACE}`, `data:config`
- **Reads**: `CONTEXT`, `KUBERNETES_DISTRIBUTION_BINARY`, `NAMESPACE`, `RESOURCE_NAME`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Fetch Mismatched FluxCD HelmRelease Version in Namespace `${NAMESPACE}`

List helmreleases and use jq to display any releases where the last attempted software revision doesn't match the current running revision. Requires jq.

- **Robot task name**: <code>Fetch Mismatched FluxCD HelmRelease Version in Namespace `${NAMESPACE}`</code>
- **Robot file**: `runbook.robot`
- **Tags**: `FluxCD`, `Helmrelease`, `Version`, `Mismatched`, `Unhealthy`, `${NAMESPACE}`, `data:config`
- **Reads**: `CONTEXT`, `KUBERNETES_DISTRIBUTION_BINARY`, `NAMESPACE`, `RESOURCE_NAME`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Fetch FluxCD HelmRelease Error Messages in Namespace `${NAMESPACE}`

List helmreleases and display the status conditions message for any helmreleases that are not in a Ready state.

- **Robot task name**: <code>Fetch FluxCD HelmRelease Error Messages in Namespace `${NAMESPACE}`</code>
- **Robot file**: `runbook.robot`
- **Tags**: `FluxCD`, `Helmrelease`, `Errors`, `Unhealthy`, `Message`, `${NAMESPACE}`, `data:config`
- **Reads**: `CONTEXT`, `KUBERNETES_DISTRIBUTION_BINARY`, `NAMESPACE`, `RESOURCE_NAME`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Check for Available Helm Chart Updates in Namespace `${NAMESPACE}`

List all helmreleases in namespace and check for available helmchart updates.

- **Robot task name**: <code>Check for Available Helm Chart Updates in Namespace `${NAMESPACE}`</code>
- **Robot file**: `runbook.robot`
- **Tags**: `FluxCD`, `Helmchart`, `Errors`, `Unhealthy`, `Message`, `HelmRelease`, `${NAMESPACE}`, `data:config`
- **Reads**: `CONTEXT`, `KUBERNETES_DISTRIBUTION_BINARY`, `NAMESPACE`, `RESOURCE_NAME`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


## Inputs

| Name | Type | Description | Default | Required |
|---|---|---|---|---|
| `DISTRIBUTION` | string | Which distribution of Kubernetes to use for operations, such as: Kubernetes, OpenShift, etc. | `Kubernetes` | no |
| `KUBERNETES_DISTRIBUTION_BINARY` | string | Which binary to use for Kubernetes CLI commands. | `kubectl` | no |
| `NAMESPACE` | string | The name of the Kubernetes namespace to scope actions and searching to. Accepts a single namespace in the format `-n namespace-name` or `--all-namespaces`. | `--all-namespaces` | no |
| `RESOURCE_NAME` | string | The short or long name of the Kubernetes helmrelease resource to search for. These might vary by helm controller implementation, and are best to use full crd name. | `helmreleases` | no |
| `CONTEXT` | string | Which Kubernetes context to operate within. | `default` | no |

## Secrets

_No secrets imported in Robot source._

## Outputs

_See Robot run output and platform report artifacts._

## How to invoke

### Preferred: Robot Framework runner (`ro`)

```bash
cd codebundles/k8s-fluxcd-helm-health
export DISTRIBUTION=...
export KUBERNETES_DISTRIBUTION_BINARY=...
export NAMESPACE=...
export RESOURCE_NAME=...
export CONTEXT=...
ro runbook.robot
```

### Standalone scripts (no Robot)


_No standalone shell scripts in this bundle._

## Source files

- `runbook.robot` — orchestrates tools and raises issues
