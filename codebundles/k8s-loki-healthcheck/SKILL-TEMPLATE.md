---
name: k8s-loki-healthcheck
kind: skill-template
description: This taskset checks the health of Grafana Loki and its hash ring. Use when triaging or monitoring RunWhen workloads with skill template `k8s-loki-healthcheck`.
runtime:
  runbook: runbook.robot
  executor: worker
  entrypoint: /home/runwhen/robot-runtime/runrobot.sh
  base_image: rw-base-runtime
platforms: [RunWhen]
resource_types: []
access: read-only
---

# Kubernetes Grafana Loki Health Check

## Summary

A set of tasks to query the state and health of a Loki deployment in Kubernetes.

See [README.md](README.md) for additional context.

## Tools

### Check Loki Ring API for Unhealthy Shards in Kubernetes Cluster `$${NAMESPACE}`

Request and inspect the state of the Loki hash rings for non-active (potentially unhealthy) shards.

- **Robot task name**: <code>Check Loki Ring API for Unhealthy Shards in Kubernetes Cluster `$${NAMESPACE}`</code>
- **Robot file**: `runbook.robot`
- **Tags**: `access:read-only`, `Loki`, `data:config`
- **Reads**: `CONTEXT`, `KUBERNETES_DISTRIBUTION_BINARY`, `NAMESPACE`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Check Loki API Ready in Kubernetes Cluster `${NAMESPACE}`

Pings the internal Loki API to check it's ready.

- **Robot task name**: <code>Check Loki API Ready in Kubernetes Cluster `${NAMESPACE}`</code>
- **Robot file**: `runbook.robot`
- **Tags**: `access:read-only`, `Loki`, `data:config`
- **Reads**: `CONTEXT`, `KUBERNETES_DISTRIBUTION_BINARY`, `NAMESPACE`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


## Inputs

| Name | Type | Description | Default | Required |
|---|---|---|---|---|
| `KUBERNETES_DISTRIBUTION_BINARY` | string | Which binary to use for Kubernetes CLI commands. | `kubectl` | no |
| `CONTEXT` | string | Which Kubernetes context to operate within. | — | yes |
| `NAMESPACE` | string | The name of the namespace to search. | `loki` | no |

## Secrets

_No secrets imported in Robot source._

## Outputs

_See Robot run output and platform report artifacts._

## How to invoke

### Production (RunWhen runner / worker)

The platform **runner** schedules work on a location **worker**. The worker
image (`rw-base-runtime`) executes Robot via `runrobot.sh` with
`RW_PATH_TO_ROBOT` set to the bound path under `/home/runwhen/collection/`.

- **Runbook**: `codebundles/k8s-loki-healthcheck/runbook.robot`

### Local development (devcontainer only)

`ro` is a dev-time wrapper in `codecollection-devtools` — not the enterprise runtime.

```bash
cd codebundles/k8s-loki-healthcheck
export KUBERNETES_DISTRIBUTION_BINARY=...
export CONTEXT=...
export NAMESPACE=...
ro runbook.robot
```

### Standalone scripts (no Robot)


_No standalone shell scripts in this bundle._

## Source files

- `runbook.robot` — orchestrates tools and raises issues
