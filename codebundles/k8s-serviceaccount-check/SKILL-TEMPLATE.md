---
name: k8s-serviceaccount-check
kind: skill-template
description: This taskset provides tasks to troubleshoot service accounts in a Kubernetes namespace. Use when triaging or monitoring Kubernetes, AKS, EKS workloads with skill template `k8s-serviceaccount-check`.
runtime:
  runbook: runbook.robot
  executor: worker
  entrypoint: /home/runwhen/robot-runtime/runrobot.sh
  base_image: rw-base-runtime
platforms: [Kubernetes, AKS, EKS, GKE, OpenShift]
resource_types: [kubernetes_resource]
access: read-only
---

# Kubernetes Service Account Check

## Summary

Tasks that help debug or validate service accounts and their access.

See [README.md](README.md) for additional context.

## Tools

### Test Service Account Access to Kubernetes API Server in Namespace `${NAMESPACE}`

Runs a curl pod as a specific serviceaccount and attempts to all the Kubernetes API server with the mounted token

- **Robot task name**: <code>Test Service Account Access to Kubernetes API Server in Namespace `${NAMESPACE}`</code>
- **Robot file**: `runbook.robot`
- **Tags**: `ServiceAccount`, `Curl`, `APIServer`, `RBAC`, `${SERVICE_ACCOUNT}`, `${NAMESPACE}`, `data:config`
- **Reads**: `CONTEXT`, `KUBERNETES_DISTRIBUTION_BINARY`, `NAMESPACE`, `SERVICE_ACCOUNT`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


## Inputs

| Name | Type | Description | Default | Required |
|---|---|---|---|---|
| `KUBERNETES_DISTRIBUTION_BINARY` | string | Which binary to use for Kubernetes CLI commands. | `kubectl` | no |
| `CONTEXT` | string | Which Kubernetes context to operate within. | — | yes |
| `NAMESPACE` | string | The name of the namespace to search. | `` | yes |
| `SERVICE_ACCOUNT` | string | The name of the namespace to search. | `default` | no |

## Secrets

_No secrets imported in Robot source._

## Outputs

_See Robot run output and platform report artifacts._

## How to invoke

### Production (RunWhen runner / worker)

The platform **runner** schedules work on a location **worker**. The worker
image (`rw-base-runtime`) executes Robot via `runrobot.sh` with
`RW_PATH_TO_ROBOT` set to the bound path under `/home/runwhen/collection/`.

- **Runbook**: `codebundles/k8s-serviceaccount-check/runbook.robot`

### Local development (devcontainer only)

`ro` is a dev-time wrapper in `codecollection-devtools` — not the enterprise runtime.

```bash
cd codebundles/k8s-serviceaccount-check
export KUBERNETES_DISTRIBUTION_BINARY=...
export CONTEXT=...
export NAMESPACE=...
export SERVICE_ACCOUNT=...
ro runbook.robot
```

### Standalone scripts (no Robot)


_No standalone shell scripts in this bundle._

## Source files

- `runbook.robot` — orchestrates tools and raises issues
