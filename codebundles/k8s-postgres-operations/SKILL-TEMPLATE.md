---
name: k8s-postgres-operations
kind: skill-template
description: PostgreSQL Operations Runbook for Kubernetes clusters. Use when triaging or monitoring Kubernetes, PostgreSQL, CrunchyDB workloads with skill template `k8s-postgres-operations`.
runtime:
  runbook: runbook.robot
  runner: ro
platforms: [Kubernetes, PostgreSQL, CrunchyDB, Zalando]
resource_types: [kubernetes_resource]
access: read-write
---

# PostgreSQL Operations

## Summary

This codebundle provides **operational remediation capabilities** for PostgreSQL clusters running in Kubernetes.

See [README.md](README.md) for additional context.

## Tools

### Reinitialize Failed PostgreSQL Cluster Members for Cluster `${OBJECT_NAME}` in Namespace `${NAMESPACE}`

Identify and reinitialize any failed cluster members

- **Robot task name**: <code>Reinitialize Failed PostgreSQL Cluster Members for Cluster `${OBJECT_NAME}` in Namespace `${NAMESPACE}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `cluster_operations.sh`
- **Tags**: `access:read-write`, `reinitialize`, `recovery`, `postgres`, `operations`
- **Reads**: —
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Perform PostgreSQL Cluster Failover Operation for Cluster `${OBJECT_NAME}` in Namespace `${NAMESPACE}`

Execute failover operation to promote a specific replica or perform automatic failover

- **Robot task name**: <code>Perform PostgreSQL Cluster Failover Operation for Cluster `${OBJECT_NAME}` in Namespace `${NAMESPACE}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `cluster_operations.sh`
- **Tags**: `access:read-write`, `failover`, `postgres`, `operations`, `emergency`
- **Reads**: `DATABASE_CONTAINER`, `OBJECT_NAME`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Restart PostgreSQL Cluster with Rolling Update for Cluster `${OBJECT_NAME}` in Namespace `${NAMESPACE}`

Perform rolling restart of all PostgreSQL cluster members

- **Robot task name**: <code>Restart PostgreSQL Cluster with Rolling Update for Cluster `${OBJECT_NAME}` in Namespace `${NAMESPACE}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `cluster_operations.sh`
- **Tags**: `access:read-write`, `restart`, `postgres`, `operations`, `maintenance`
- **Reads**: `DATABASE_CONTAINER`, `NAMESPACE`, `OBJECT_NAME`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Verify Cluster Recovery and Generate Summary for Cluster `${OBJECT_NAME}` in Namespace `${NAMESPACE}`

Final verification of cluster health after operations

- **Robot task name**: <code>Verify Cluster Recovery and Generate Summary for Cluster `${OBJECT_NAME}` in Namespace `${NAMESPACE}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `cluster_operations.sh`
- **Tags**: `access:read-write`, `verification`, `summary`, `postgres`
- **Reads**: `NAMESPACE`, `OBJECT_NAME`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


## Inputs

| Name | Type | Description | Default | Required |
|---|---|---|---|---|
| `KUBERNETES_DISTRIBUTION_BINARY` | string | Which binary to use for Kubernetes CLI commands. | `kubectl` | no |
| `CONTEXT` | string | Which Kubernetes context to operate within. | — | yes |
| `NAMESPACE` | string | The name of the Kubernetes namespace to scope actions and searching to. | — | yes |
| `OBJECT_NAME` | string | The name of the PostgreSQL cluster object. | — | yes |
| `OBJECT_API_VERSION` | string | The API version of the PostgreSQL cluster object. | — | yes |
| `DATABASE_CONTAINER` | string | The name of the database container in the PostgreSQL pods. | `database` | no |

## Secrets

_No secrets imported in Robot source._

## Outputs

_See Robot run output and platform report artifacts._

## How to invoke

### Preferred: Robot Framework runner (`ro`)

```bash
cd codebundles/k8s-postgres-operations
export KUBERNETES_DISTRIBUTION_BINARY=...
export CONTEXT=...
export NAMESPACE=...
export OBJECT_NAME=...
export OBJECT_API_VERSION=...
export DATABASE_CONTAINER=...
ro runbook.robot
```

### Standalone scripts (no Robot)


Set the input variables above, then run the matching script:

```bash
cd codebundles/k8s-postgres-operations
export KUBERNETES_DISTRIBUTION_BINARY=...
export CONTEXT=...
export NAMESPACE=...
export OBJECT_NAME=...
bash cluster_operations.sh
```

## Source files

- `runbook.robot` — orchestrates tools and raises issues
- `cluster_operations.sh` — Bash helper script `cluster_operations.sh`.
