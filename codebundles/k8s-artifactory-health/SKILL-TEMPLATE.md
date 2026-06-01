---
name: k8s-artifactory-health
kind: skill-template
description: Performs a triage on the Open Source version of Artifactory in a Kubernetes cluster. Use when triaging or monitoring Kubernetes, AKS, EKS workloads with skill template `k8s-artifactory-health`.
runtime:
  runbook: runbook.robot
  runner: ro
platforms: [Kubernetes, AKS, EKS, GKE, OpenShift, Artifactory]
resource_types: [kubernetes_resource]
access: read-only
---

# Kubernetes Artifactory Triage

## Summary

This codebundle queries the health REST endpoints of an Artifactory workload in Kubernetes, checking if the service is healthy, and raising issues if it's not.

See [README.md](README.md) for additional context.

## Tools

### Check Artifactory Liveness and Readiness Endpoints in `NAMESPACE`

Runs a set of exec commands internally in the Artifactory workloads to curl the system health endpoints.

- **Robot task name**: <code>Check Artifactory Liveness and Readiness Endpoints in `NAMESPACE`</code>
- **Robot file**: `runbook.robot`
- **Tags**: `Pods`, `Statefulset`, `Artifactory`, `Health`, `System`, `Curl`, `API`, `OK`, `HTTP`, `access:read-only`, `data:config`
- **Reads**: `CONTEXT`, `KUBERNETES_DISTRIBUTION_BINARY`, `NAMESPACE`, `STATEFULSET_NAME`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


## Inputs

| Name | Type | Description | Default | Required |
|---|---|---|---|---|
| `STATEFULSET_NAME` | string | The name of the Artifactory statefulset. | `artifactory-oss` | no |
| `NAMESPACE` | string | The name of the Kubernetes namespace that the Artifactory workloads reside in. | `artifactory` | no |
| `CONTEXT` | string | Which Kubernetes context to operate within. | — | yes |
| `LABELS` | string | The Kubernetes labels used to fetch the first matching statefulset. | `` | yes |
| `EXPECTED_AVAILABILITY` | string | The minimum numbers of replicas allowed considered healthy. | `2` | no |
| `KUBERNETES_DISTRIBUTION_BINARY` | string | Which binary to use for CLI commands | `kubectl` | no |

## Secrets

| Name | Description | Required |
|---|---|---|
| `kubeconfig` | The kubernetes kubeconfig yaml containing connection configuration used to connect to cluster(s). | yes |

## Outputs

_See Robot run output and platform report artifacts._

## How to invoke

### Preferred: Robot Framework runner (`ro`)

```bash
cd codebundles/k8s-artifactory-health
export STATEFULSET_NAME=...
export NAMESPACE=...
export CONTEXT=...
export LABELS=...
export EXPECTED_AVAILABILITY=...
ro runbook.robot
```

### Standalone scripts (no Robot)


_No standalone shell scripts in this bundle._

## Source files

- `runbook.robot` — orchestrates tools and raises issues
