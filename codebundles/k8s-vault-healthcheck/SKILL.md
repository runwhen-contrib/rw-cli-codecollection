---
name: k8s-vault-healthcheck
description: A suite of tasks that can be used to triage potential issues in your vault namespace. Use when triaging or monitoring AKS, EKS, GKE workloads with skill template `k8s-vault-healthcheck`.
runtime:
  runbook: runbook.robot
  runner: ro
platforms: [AKS, EKS, GKE, Kubernetes, Vault]
resource_types: [kubernetes_resource]
access: read-only
---

# Kubernetes Vault Triage

## Summary

A taskset which checks the status of a Vault workload in Kubernetes.

See [README.md](README.md) for additional context.

## Tools

### Fetch Vault CSI Driver Logs in Namespace `${NAMESPACE}`

Fetches the last 100 lines of logs for the vault CSI driver.

- **Robot task name**: <code>Fetch Vault CSI Driver Logs in Namespace `${NAMESPACE}`</code>
- **Robot file**: `runbook.robot`
- **Tags**: `access:read-only`, `fetch`, `log`, `pod`, `container`, `errors`, `inspect`, `trace`, `info`, `vault`, `csi`, `driver`, `data:logs-bulk`
- **Reads**: `CONTEXT`, `KUBERNETES_DISTRIBUTION_BINARY`, `NAMESPACE`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Get Vault CSI Driver Warning Events in `${NAMESPACE}`

Fetches warning-type events related to the vault CSI driver.

- **Robot task name**: <code>Get Vault CSI Driver Warning Events in `${NAMESPACE}`</code>
- **Robot file**: `runbook.robot`
- **Tags**: `access:read-only`, `events`, `errors`, `warnings`, `get`, `vault`, `csi`, `driver`, `data:config`
- **Reads**: `CONTEXT`, `KUBERNETES_DISTRIBUTION_BINARY`, `NAMESPACE`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Check Vault CSI Driver Replicas

Performs an inspection on the replicas of the vault CSI driver daemonset.

- **Robot task name**: <code>Check Vault CSI Driver Replicas</code>
- **Robot file**: `runbook.robot`
- **Tags**: —
- **Reads**: `CONTEXT`, `KUBERNETES_DISTRIBUTION_BINARY`, `NAMESPACE`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Fetch Vault Pod Workload Logs in Namespace `${NAMESPACE}` with Labels `${LABELS}`

Fetches the last 100 lines of logs for all vault pod workloads in the vault namespace.

- **Robot task name**: <code>Fetch Vault Pod Workload Logs in Namespace `${NAMESPACE}` with Labels `${LABELS}`</code>
- **Robot file**: `runbook.robot`
- **Tags**: `access:read-only`, `fetch`, `log`, `pod`, `container`, `errors`, `inspect`, `trace`, `info`, `statefulset`, `vault`, `data:logs-bulk`
- **Reads**: `CONTEXT`, `KUBERNETES_DISTRIBUTION_BINARY`, `NAMESPACE`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Get Related Vault Events in Namespace `${NAMESPACE}`

Fetches all warning-type events related to vault in the vault namespace.

- **Robot task name**: <code>Get Related Vault Events in Namespace `${NAMESPACE}`</code>
- **Robot file**: `runbook.robot`
- **Tags**: `access:read-only`, `events`, `workloads`, `errors`, `warnings`, `get`, `statefulset`, `vault`, `data:config`
- **Reads**: `CONTEXT`, `KUBERNETES_DISTRIBUTION_BINARY`, `NAMESPACE`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Fetch Vault StatefulSet Manifest Details in `${NAMESPACE}`

Fetches the current state of the vault statefulset manifest for inspection.

- **Robot task name**: <code>Fetch Vault StatefulSet Manifest Details in `${NAMESPACE}`</code>
- **Robot file**: `runbook.robot`
- **Tags**: `access:read-only`, `statefulset`, `details`, `manifest`, `info`, `vault`, `data:config`
- **Reads**: `CONTEXT`, `KUBERNETES_DISTRIBUTION_BINARY`, `NAMESPACE`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Fetch Vault DaemonSet Manifest Details in Kubernetes Cluster `${NAMESPACE}`

Fetches the current state of the vault daemonset manifest for inspection.

- **Robot task name**: <code>Fetch Vault DaemonSet Manifest Details in Kubernetes Cluster `${NAMESPACE}`</code>
- **Robot file**: `runbook.robot`
- **Tags**: `access:read-only`, `statefulset`, `details`, `manifest`, `info`, `vault`, `data:config`
- **Reads**: `CONTEXT`, `KUBERNETES_DISTRIBUTION_BINARY`, `NAMESPACE`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Verify Vault Availability in Namespace `${NAMESPACE}` and Context `${CONTEXT}`

Curls the vault endpoint and checks the HTTP response code.

- **Robot task name**: <code>Verify Vault Availability in Namespace `${NAMESPACE}` and Context `${CONTEXT}`</code>
- **Robot file**: `runbook.robot`
- **Tags**: `access:read-only`, `http`, `curl`, `vault`, `web`, `code`, `ok`, `available`, `data:config`
- **Reads**: `NAMESPACE`, `VAULT_URL`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Check Vault StatefulSet Replicas in `NAMESPACE`

Pulls the replica information for the Vault statefulset and checks if it's highly available

- **Robot task name**: <code>Check Vault StatefulSet Replicas in `NAMESPACE`</code>
- **Robot file**: `runbook.robot`
- **Tags**: —
- **Reads**: `CONTEXT`, `KUBERNETES_DISTRIBUTION_BINARY`, `NAMESPACE`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


## Inputs

| Name | Type | Description | Default | Required |
|---|---|---|---|---|
| `NAMESPACE` | string | The namespace that your vault workloads reside in. Typically 'vault'. | `vault` | no |
| `CONTEXT` | string | Which Kubernetes context to operate within. | — | yes |
| `LABELS` | string | Additional labels to use when selecting vault resources during triage. | — | yes |
| `VAULT_URL` | string | The URL of the vault instance to check. | — | yes |
| `KUBERNETES_DISTRIBUTION_BINARY` | string | Which binary to use for Kubernetes CLI commands. | `kubectl` | no |

## Secrets

_No secrets imported in Robot source._

## Outputs

_See Robot run output and platform report artifacts._

## How to invoke

### Preferred: Robot Framework runner (`ro`)

```bash
cd codebundles/k8s-vault-healthcheck
export NAMESPACE=...
export CONTEXT=...
export LABELS=...
export VAULT_URL=...
export KUBERNETES_DISTRIBUTION_BINARY=...
ro runbook.robot
```

### Standalone scripts (no Robot)


_No standalone shell scripts in this bundle._

## Source files

- `runbook.robot` — orchestrates tools and raises issues
