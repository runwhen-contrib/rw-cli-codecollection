---
name: k8s-ingress-healthcheck
description: Triages issues related to a ingress objects and services. Use when triaging or monitoring Kubernetes, AKS, EKS workloads with skill template `k8s-ingress-healthcheck`.
runtime:
  runbook: runbook.robot
  runner: ro
platforms: [Kubernetes, AKS, EKS, GKE, OpenShift]
resource_types: [ingress]
access: read-only
---

# Kubernetes Ingress Healthcheck

## Summary

The `k8s-ingress-healthchech` codebundle checks the health of ingress objects within a Namespace.

See [README.md](README.md) for additional context.

## Tools

### Fetch Ingress Object Health in Namespace `${NAMESPACE}`

Fetches all ingress objects in the namespace and outputs the name, health status, services, and endpoints.

- **Robot task name**: <code>Fetch Ingress Object Health in Namespace `${NAMESPACE}`</code>
- **Robot file**: `runbook.robot`
- **Tags**: `service`, `ingress`, `endpoint`, `health`, `${NAMESPACE}`, `data:config`
- **Reads**: `CONTEXT`, `KUBERNETES_DISTRIBUTION_BINARY`, `NAMESPACE`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Check for Ingress and Service Conflicts in Namespace `${NAMESPACE}`

Look for conflicting configuration between service and ingress objects.

- **Robot task name**: <code>Check for Ingress and Service Conflicts in Namespace `${NAMESPACE}`</code>
- **Robot file**: `runbook.robot`
- **Tags**: `service`, `ingress`, `health`, `conflict`, `${NAMESPACE}`, `data:config`
- **Reads**: `CONTEXT`, `KUBERNETES_DISTRIBUTION_BINARY`, `NAMESPACE`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


## Inputs

| Name | Type | Description | Default | Required |
|---|---|---|---|---|
| `NAMESPACE` | string | The name of the Kubernetes namespace to scope actions and searching to. | — | yes |
| `CONTEXT` | string | Which Kubernetes context to operate within. | — | yes |
| `KUBERNETES_DISTRIBUTION_BINARY` | string | Which binary to use for Kubernetes CLI commands. | `kubectl` | no |

## Secrets

_No secrets imported in Robot source._

## Outputs

_See Robot run output and platform report artifacts._

## How to invoke

### Preferred: Robot Framework runner (`ro`)

```bash
cd codebundles/k8s-ingress-healthcheck
export NAMESPACE=...
export CONTEXT=...
export KUBERNETES_DISTRIBUTION_BINARY=...
ro runbook.robot
```

### Standalone scripts (no Robot)


_No standalone shell scripts in this bundle._

## Source files

- `runbook.robot` — orchestrates tools and raises issues
