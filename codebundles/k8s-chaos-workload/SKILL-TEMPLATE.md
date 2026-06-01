---
name: k8s-chaos-workload
kind: skill-template
description: Provides chaos injection tasks for specific workloads like your apps in a Kubernetes namespace. These are... Use when triaging or monitoring Kubernetes, Chaos, Engineering workloads with skill temp...
runtime:
  runbook: runbook.robot
  runner: ro
platforms: [Kubernetes, Chaos, Engineering, Workload, Application, Deployments, StatefulSet]
resource_types: [kubernetes_resource]
access: read-write
---

# Kubernetes Workload Chaos Engineering

## Summary

This codebundle provides chaos injection for a specific workload within a Kubernetes namespace.

See [README.md](README.md) for additional context.

## Tools

### Test `${WORKLOAD_NAME}` High Availability in Namespace `${NAMESPACE}`

Kills a pod under this workload to test high availability.

- **Robot task name**: <code>Test `${WORKLOAD_NAME}` High Availability in Namespace `${NAMESPACE}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `kill_workload_pod.sh`
- **Tags**: `Kubernetes`, `StatefulSet`, `Deployments`, `Pods`, `Highly`, `Available`, `access:read-write`
- **Reads**: —
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### OOMKill `${WORKLOAD_NAME}` Pod

Kills the oldest pod running under the configured workload.

- **Robot task name**: <code>OOMKill `${WORKLOAD_NAME}` Pod</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `oomkill_workload_pod.sh`
- **Tags**: `Kubernetes`, `StatefulSet`, `Deployments`, `Pods`, `Highly`, `Available`, `OOMkill`, `Memory`, `access:read-write`
- **Reads**: —
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Mangle Service Selector For `${WORKLOAD_NAME}` in `${NAMESPACE}`

Breaks a service's label selector to cause a network disruption

- **Robot task name**: <code>Mangle Service Selector For `${WORKLOAD_NAME}` in `${NAMESPACE}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `change_service_selector.sh`
- **Tags**: `Kubernetes`, `networking`, `Services`, `Selector`, `access:read-only`
- **Reads**: —
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Mangle Service Port For `${WORKLOAD_NAME}` in `${NAMESPACE}`

Changes a service's port to cause a network disruption

- **Robot task name**: <code>Mangle Service Port For `${WORKLOAD_NAME}` in `${NAMESPACE}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `change_service_port.sh`
- **Tags**: `Kubernetes`, `networking`, `Services`, `Port`, `access:read-write`
- **Reads**: —
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Fill Tmp Directory Of Pod From `${WORKLOAD_NAME}`

Attaches to a pod and fills the /tmp directory with random data

- **Robot task name**: <code>Fill Tmp Directory Of Pod From `${WORKLOAD_NAME}`</code>
- **Robot file**: `runbook.robot`
- **Tags**: `Kubernetes`, `pods`, `volumes`, `tmp`, `access:read-write`
- **Reads**: —
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


## Inputs

| Name | Type | Description | Default | Required |
|---|---|---|---|---|
| `CONTEXT` | string | The kubernetes context to use in the kubeconfig provided. | — | yes |
| `NAMESPACE` | string | The namespace to target for scripts. | — | yes |
| `WORKLOAD_NAME` | string | The name of the workload to perform chaos testing on. Include the kind in the name, eg: deployment/my-app | — | yes |

## Secrets

| Name | Description | Required |
|---|---|---|
| `kubeconfig` | The kubeconfig secret to use for authenticating with the cluster. | yes |

## Outputs

_See Robot run output and platform report artifacts._

## How to invoke

### Preferred: Robot Framework runner (`ro`)

```bash
cd codebundles/k8s-chaos-workload
export CONTEXT=...
export NAMESPACE=...
export WORKLOAD_NAME=...
ro runbook.robot
```

### Standalone scripts (no Robot)


Set the input variables above, then run the matching script:

```bash
cd codebundles/k8s-chaos-workload
export CONTEXT=...
export NAMESPACE=...
export WORKLOAD_NAME=...
bash change_service_port.sh
bash change_service_selector.sh
bash expand_tmp.sh
bash kill_workload_pod.sh
bash oomkill_workload_pod.sh
```

## Source files

- `runbook.robot` — orchestrates tools and raises issues
- `change_service_port.sh` — Bash helper script `change_service_port.sh`.
- `change_service_selector.sh` — Bash helper script `change_service_selector.sh`.
- `expand_tmp.sh` — Bash helper script `expand_tmp.sh`.
- `kill_workload_pod.sh` — Bash helper script `kill_workload_pod.sh`.
- `oomkill_workload_pod.sh` — Bash helper script `oomkill_workload_pod.sh`.
