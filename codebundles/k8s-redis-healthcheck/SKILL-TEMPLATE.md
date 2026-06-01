---
name: k8s-redis-healthcheck
kind: skill-template
description: This taskset collects information on your redis workload in your Kubernetes cluster and raises issues if any health... Use when triaging or monitoring Kubernetes, AKS, EKS workloads with skill temp...
runtime:
  runbook: runbook.robot
  runner: ro
platforms: [Kubernetes, AKS, EKS, GKE, OpenShift, Redis]
resource_types: [kubernetes_resource]
access: read-only
---

# Kubernetes Redis Healthcheck

## Summary

A set of tasks which performs a health check and read/write verification on a Redis workload running in a Kubernetes cluster.

See [README.md](README.md) for additional context.

## Tools

### Ping `${DEPLOYMENT_NAME}` Redis Workload

Verifies that a PING can be peformed against the redis workload.

- **Robot task name**: <code>Ping `${DEPLOYMENT_NAME}` Redis Workload</code>
- **Robot file**: `runbook.robot`
- **Tags**: `access:read-only`, `redis`, `cli`, `ping`, `pong`, `alive`, `probe`, `ready`, `data:config`
- **Reads**: `CONTEXT`, `DEPLOYMENT_NAME`, `KUBERNETES_DISTRIBUTION_BINARY`, `NAMESPACE`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Verify `${DEPLOYMENT_NAME}` Redis Read Write Operation in Kubernetes

Attempts to perform a write and read operation on the redis workload, checking that a key can be set, incremented, and read from.

- **Robot task name**: <code>Verify `${DEPLOYMENT_NAME}` Redis Read Write Operation in Kubernetes</code>
- **Robot file**: `runbook.robot`
- **Tags**: `access:read-only`, `redis`, `cli`, `increment`, `health`, `check`, `read`, `write`, `data:config`
- **Reads**: `CONTEXT`, `DEPLOYMENT_NAME`, `KUBERNETES_DISTRIBUTION_BINARY`, `NAMESPACE`, `REDIS_HEALTHCHECK_KEY`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


## Inputs

| Name | Type | Description | Default | Required |
|---|---|---|---|---|
| `KUBERNETES_DISTRIBUTION_BINARY` | string | Which binary to use for Kubernetes CLI commands. | `kubectl` | no |
| `CONTEXT` | string | Which Kubernetes context to operate within. | — | yes |
| `NAMESPACE` | string | The name of the namespace to search. | `` | yes |
| `DEPLOYMENT_NAME` | string | Used to target the redis resource for the health check. | — | yes |
| `REDIS_HEALTHCHECK_KEY` | string | The key used to perform read/write operations on to validate storage. | `runwhen_task_rw_healthcheck` | no |

## Secrets

_No secrets imported in Robot source._

## Outputs

_See Robot run output and platform report artifacts._

## How to invoke

### Preferred: Robot Framework runner (`ro`)

```bash
cd codebundles/k8s-redis-healthcheck
export KUBERNETES_DISTRIBUTION_BINARY=...
export CONTEXT=...
export NAMESPACE=...
export DEPLOYMENT_NAME=...
export REDIS_HEALTHCHECK_KEY=...
ro runbook.robot
```

### Standalone scripts (no Robot)


_No standalone shell scripts in this bundle._

## Source files

- `runbook.robot` — orchestrates tools and raises issues
