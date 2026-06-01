---
name: k8s-restart-resource
kind: skill-template
description: This taskset restarts a resource with a given set of labels, typically used with other tasksets. Use when triaging or monitoring Kubernetes, AKS, EKS workloads with skill template `k8s-restart-reso...
runtime:
  runbook: runbook.robot
  runner: ro
platforms: [Kubernetes, AKS, EKS, GKE, OpenShift]
resource_types: [kubernetes_resource]
access: read-write
---

# Kubernetes Restart resource

## Summary

Restarts a kubernetes resource in an attempt to get it out of a bad state.

See [README.md](README.md) for additional context.

## Tools

### Get Current Resource State with Labels `${LABELS}`

Gets the current state of the resource before applying the restart for report review.

- **Robot task name**: <code>Get Current Resource State with Labels `${LABELS}`</code>
- **Robot file**: `runbook.robot`
- **Tags**: `access:read-only`, `resource`, `application`, `restart`, `state`, `yaml`, `data:config`
- **Reads**: `CONTEXT`, `KUBERNETES_DISTRIBUTION_BINARY`, `LABELS`, `NAMESPACE`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Get Resource Logs with Labels `${LABELS}`

Collects the last approximately 200 lines of logs from the resource before restarting it.

- **Robot task name**: <code>Get Resource Logs with Labels `${LABELS}`</code>
- **Robot file**: `runbook.robot`
- **Tags**: `access:read-only`, `resource`, `application`, `workload`, `logs`, `state`, `data:logs-bulk`
- **Reads**: `CONTEXT`, `KUBERNETES_DISTRIBUTION_BINARY`, `LABELS`, `NAMESPACE`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Restart Resource with Labels `${LABELS}` in `${CONTEXT}`

Restarts the labeled resource in an attempt to get it out of a bad state.

- **Robot task name**: <code>Restart Resource with Labels `${LABELS}` in `${CONTEXT}`</code>
- **Robot file**: `runbook.robot`
- **Tags**: `access:read-write`, `resource`, `application`, `restart`, `pod`, `kill`, `rollout`, `revision`
- **Reads**: `CONTEXT`, `KUBERNETES_DISTRIBUTION_BINARY`, `LABELS`, `NAMESPACE`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


## Inputs

| Name | Type | Description | Default | Required |
|---|---|---|---|---|
| `KUBERNETES_DISTRIBUTION_BINARY` | string | Which binary to use for Kubernetes CLI commands. | `kubectl` | no |
| `CONTEXT` | string | Which Kubernetes context to operate within. | — | yes |
| `NAMESPACE` | string | The name of the namespace to search. | `` | yes |
| `LABELS` | string | The kubectl label string to use for selecting the resource. | `` | yes |

## Secrets

_No secrets imported in Robot source._

## Outputs

_See Robot run output and platform report artifacts._

## How to invoke

### Preferred: Robot Framework runner (`ro`)

```bash
cd codebundles/k8s-restart-resource
export KUBERNETES_DISTRIBUTION_BINARY=...
export CONTEXT=...
export NAMESPACE=...
export LABELS=...
ro runbook.robot
```

### Standalone scripts (no Robot)


_No standalone shell scripts in this bundle._

## Source files

- `runbook.robot` — orchestrates tools and raises issues
