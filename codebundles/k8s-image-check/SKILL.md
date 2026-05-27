---
name: k8s-image-check
description: This taskset provides detailed information about the images used in a Kubernetes namespace. Use when triaging or monitoring Kubernetes, AKS, EKS workloads with skill template `k8s-image-check`.
runtime:
  runbook: runbook.robot
  runner: ro
platforms: [Kubernetes, AKS, EKS, GKE, OpenShift]
resource_types: [kubernetes_resource]
access: read-only
---

# Kubernetes Image Check

## Summary

Simple informational report that provides information about images in a namespace.

See [README.md](README.md) for additional context.

## Tools

### Check Image Rollover Times for Namespace `${NAMESPACE}`

Fetches and checks when images last rolled over in a namespace.

- **Robot task name**: <code>Check Image Rollover Times for Namespace `${NAMESPACE}`</code>
- **Robot file**: `runbook.robot`
- **Tags**: —
- **Reads**: `CONTEXT`, `KUBERNETES_DISTRIBUTION_BINARY`, `NAMESPACE`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### List Images and Tags for Every Container in Running Pods for Namespace `${NAMESPACE}`

Display the status, image name, image tag, and container name for running pods in the namespace.

- **Robot task name**: <code>List Images and Tags for Every Container in Running Pods for Namespace `${NAMESPACE}`</code>
- **Robot file**: `runbook.robot`
- **Tags**: `pods`, `containers`, `image`, `images`, `tag`, `data:config`
- **Reads**: `CONTEXT`, `KUBERNETES_DISTRIBUTION_BINARY`, `NAMESPACE`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### List Images and Tags for Every Container in Failed Pods for Namespace `${NAMESPACE}`

Display the status, image name, image tag, and container name for failed pods in the namespace.

- **Robot task name**: <code>List Images and Tags for Every Container in Failed Pods for Namespace `${NAMESPACE}`</code>
- **Robot file**: `runbook.robot`
- **Tags**: `pods`, `containers`, `image`, `images`, `tag`, `data:config`
- **Reads**: `CONTEXT`, `KUBERNETES_DISTRIBUTION_BINARY`, `NAMESPACE`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### List ImagePullBackOff Events and Test Path and Tags for Namespace `${NAMESPACE}`

Search events in the last 5 minutes for BackOff events related to image pull issues. Run Skopeo to test if the image path exists and what tags are available.

- **Robot task name**: <code>List ImagePullBackOff Events and Test Path and Tags for Namespace `${NAMESPACE}`</code>
- **Robot file**: `runbook.robot`
- **Tags**: `containers`, `image`, `images`, `tag`, `imagepullbackoff`, `skopeo`, `backoff`, `data:config`
- **Reads**: `CONTEXT`, `KUBERNETES_DISTRIBUTION_BINARY`, `NAMESPACE`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


## Inputs

| Name | Type | Description | Default | Required |
|---|---|---|---|---|
| `KUBERNETES_DISTRIBUTION_BINARY` | string | Which binary to use for Kubernetes CLI commands. | `kubectl` | no |
| `CONTEXT` | string | Which Kubernetes context to operate within. | — | yes |
| `NAMESPACE` | string | The name of the namespace to search. | `` | yes |

## Secrets

_No secrets imported in Robot source._

## Outputs

_See Robot run output and platform report artifacts._

## How to invoke

### Preferred: Robot Framework runner (`ro`)

```bash
cd codebundles/k8s-image-check
export KUBERNETES_DISTRIBUTION_BINARY=...
export CONTEXT=...
export NAMESPACE=...
ro runbook.robot
```

### Standalone scripts (no Robot)


_No standalone shell scripts in this bundle._

## Source files

- `runbook.robot` — orchestrates tools and raises issues
