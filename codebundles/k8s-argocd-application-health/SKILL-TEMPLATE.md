---
name: k8s-argocd-application-health
kind: skill-template
description: This taskset collects information and runs general troubleshooting checks against argocd application objects within... Use when triaging or monitoring Kubernetes, AKS, EKS workloads with skill temp...
runtime:
  runbook: runbook.robot
  executor: worker
  entrypoint: /home/runwhen/robot-runtime/runrobot.sh
  base_image: rw-base-runtime
platforms: [Kubernetes, AKS, EKS, GKE, OpenShift, ArgoCD]
resource_types: [kubernetes_resource]
access: read-only
---

# Kubernetes ArgoCD Application Health & Troubleshoot

## Summary

This codebundle is used to help measure and troubleshoot the health of an ArgoCD managed application.

See [README.md](README.md) for additional context.

## Tools

### Fetch ArgoCD Application Sync Status & Health for `${APPLICATION}`

Shows the sync status and health of the ArgoCD application.

- **Robot task name**: <code>Fetch ArgoCD Application Sync Status & Health for `${APPLICATION}`</code>
- **Robot file**: `runbook.robot`
- **Tags**: `Application`, `Sync`, `Health`, `ArgoCD`, `data:config`
- **Reads**: `APPLICATION`, `APPLICATION_APP_NAMESPACE`, `CONTEXT`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Fetch ArgoCD Application Last Sync Operation Details for `${APPLICATION}`

Fetches the last ArgoCD Application sync operation staus.

- **Robot task name**: <code>Fetch ArgoCD Application Last Sync Operation Details for `${APPLICATION}`</code>
- **Robot file**: `runbook.robot`
- **Tags**: `Application`, `SyncOperation`, `History`, `ArgoCD`, `data:config`
- **Reads**: `APPLICATION`, `APPLICATION_APP_NAMESPACE`, `CONTEXT`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Fetch Unhealthy ArgoCD Application Resources for `${APPLICATION}`

Displays all resources in an ArgoCD Application that are not in a healthy state.

- **Robot task name**: <code>Fetch Unhealthy ArgoCD Application Resources for `${APPLICATION}`</code>
- **Robot file**: `runbook.robot`
- **Tags**: `Resources`, `Unhealthy`, `SyncStatus`, `ArgoCD`, `data:config`
- **Reads**: `APPLICATION`, `APPLICATION_APP_NAMESPACE`, `APPLICATION_TARGET_NAMESPACE`, `CONTEXT`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Scan For Errors in Pod Logs Related to ArgoCD Application `${APPLICATION}`

Grep for the error pattern across all pods managed by this Applications deployments.

- **Robot task name**: <code>Scan For Errors in Pod Logs Related to ArgoCD Application `${APPLICATION}`</code>
- **Robot file**: `runbook.robot`
- **Tags**: `Error`, `Logs`, `Deployments`, `ArgoCD`, `Pods`, `data:logs-regexp`
- **Reads**: `APPLICATION`, `APPLICATION_TARGET_NAMESPACE`, `ERROR_PATTERN`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Fully Describe ArgoCD Application `${APPLICATION}`

Describe all details regarding the ArgoCD Application. Useful if reviewing all content.

- **Robot task name**: <code>Fully Describe ArgoCD Application `${APPLICATION}`</code>
- **Robot file**: `runbook.robot`
- **Tags**: `Application`, `Describe`, `ArgoCD`, `data:config`
- **Reads**: `APPLICATION`, `APPLICATION_APP_NAMESPACE`, `CONTEXT`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


## Inputs

| Name | Type | Description | Default | Required |
|---|---|---|---|---|
| `binary_name` | string | The Kubernetes cli binary to use. | `kubectl` | no |
| `CONTEXT` | string | Which Kubernetes context to operate within. | — | yes |
| `ERROR_PATTERN` | string | The error pattern to use when grep-ing logs. | `Error|Exception` | no |
| `APPLICATION` | string | The name of the ArgoCD Application to query. Leave blank to query all applications within the namespace. | `''` | no |
| `APPLICATION_TARGET_NAMESPACE` | string | The name of the Kubernetes namespace where the application resources are deployed to. | — | yes |
| `APPLICATION_APP_NAMESPACE` | string | The name of the Kubernetes namespace in which the ArgoCD Application resource exists. | — | yes |

## Secrets

_No secrets imported in Robot source._

## Outputs

_See Robot run output and platform report artifacts._

## How to invoke

### Production (RunWhen runner / worker)

The platform **runner** schedules work on a location **worker**. The worker
image (`rw-base-runtime`) executes Robot via `runrobot.sh` with
`RW_PATH_TO_ROBOT` set to the bound path under `/home/runwhen/collection/`.

- **Runbook**: `codebundles/k8s-argocd-application-health/runbook.robot`

### Local development (devcontainer only)

`ro` is a dev-time wrapper in `codecollection-devtools` — not the enterprise runtime.

```bash
cd codebundles/k8s-argocd-application-health
export binary_name=...
export CONTEXT=...
export ERROR_PATTERN=...
export APPLICATION=...
export APPLICATION_TARGET_NAMESPACE=...
export APPLICATION_APP_NAMESPACE=...
ro runbook.robot
```

### Standalone scripts (no Robot)


_No standalone shell scripts in this bundle._

## Source files

- `runbook.robot` — orchestrates tools and raises issues
