---
name: k8s-chaos-namespace
kind: skill-template
description: Provides chaos injection tasks for Kubernetes namespaces. These are destructive tasks and the expectation is that... Use when triaging or monitoring Kubernetes, Chaos, Engineering workloads with sk...
runtime:
  runbook: runbook.robot
  executor: worker
  entrypoint: /home/runwhen/robot-runtime/runrobot.sh
  base_image: rw-base-runtime
platforms: [Kubernetes, Chaos, Engineering, Namespace]
resource_types: [namespace]
access: read-only
---

# Kubernetes Namespace Chaos Engineering

## Summary

This codebundle provides chaos injection for kubernetes namespaces `Test Namespace Highly Available`.

See [README.md](README.md) for additional context.

## Tools

### Kill Random Pods In Namespace `${NAMESPACE}`

Randomly selects up to 10 pods in a namespace to delete to test HA

- **Robot task name**: <code>Kill Random Pods In Namespace `${NAMESPACE}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `delete_random_pods.sh`
- **Tags**: `Kubernetes`, `Namespace`, `Deployments`, `Pods`, `Highly`, `Available`
- **Reads**: —
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### OOMKill Pods In Namespace `${NAMESPACE}`

Randomly selects n number of pods to oomkill

- **Robot task name**: <code>OOMKill Pods In Namespace `${NAMESPACE}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `oomkill_pod.sh`
- **Tags**: `Kubernetes`, `Namespace`, `Deployments`, `Pods`, `Highly`, `Available`, `OOMkill`, `Memory`
- **Reads**: —
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Mangle Service Selector In Namespace `${NAMESPACE}`

Breaks a service's label selector to cause a network disruption

- **Robot task name**: <code>Mangle Service Selector In Namespace `${NAMESPACE}`</code>
- **Robot file**: `runbook.robot`
- **Tags**: `Kubernetes`, `networking`, `Services`, `Selector`
- **Reads**: —
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Mangle Service Port In Namespace `${NAMESPACE}`

Changes a service's port to cause a network disruption

- **Robot task name**: <code>Mangle Service Port In Namespace `${NAMESPACE}`</code>
- **Robot file**: `runbook.robot`
- **Tags**: `Kubernetes`, `networking`, `Services`, `Port`
- **Reads**: —
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Fill Random Pod Tmp Directory In Namespace `${NAMESPACE}`

Attaches to a pod and fills the /tmp directory with random data

- **Robot task name**: <code>Fill Random Pod Tmp Directory In Namespace `${NAMESPACE}`</code>
- **Robot file**: `runbook.robot`
- **Tags**: `Kubernetes`, `pods`, `volumes`, `tmp`
- **Reads**: —
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


## Inputs

| Name | Type | Description | Default | Required |
|---|---|---|---|---|
| `CONTEXT` | string | The kubernetes context to use in the kubeconfig provided. | — | yes |
| `NAMESPACE` | string | The namespace to target for scripts. | — | yes |

## Secrets

| Name | Description | Required |
|---|---|---|
| `kubeconfig` | The kubeconfig secret to use for authenticating with the cluster. | yes |

## Outputs

_See Robot run output and platform report artifacts._

## How to invoke

### Production (RunWhen runner / worker)

The platform **runner** schedules work on a location **worker**. The worker
image (`rw-base-runtime`) executes Robot via `runrobot.sh` with
`RW_PATH_TO_ROBOT` set to the bound path under `/home/runwhen/collection/`.

- **Runbook**: `codebundles/k8s-chaos-namespace/runbook.robot`

### Local development (devcontainer only)

`ro` is a dev-time wrapper in `codecollection-devtools` — not the enterprise runtime.

```bash
cd codebundles/k8s-chaos-namespace
export CONTEXT=...
export NAMESPACE=...
ro runbook.robot
```

### Standalone scripts (no Robot)


Set the input variables above, then run the matching script:

```bash
cd codebundles/k8s-chaos-namespace
export CONTEXT=...
export NAMESPACE=...
bash change_service_port.sh
bash change_service_selector.sh
bash delete_random_pods.sh
bash drain_node.sh
bash expand_tmp.sh
bash oomkill_pod.sh
```

## Source files

- `runbook.robot` — orchestrates tools and raises issues
- `change_service_port.sh` — Bash helper script `change_service_port.sh`.
- `change_service_selector.sh` — Bash helper script `change_service_selector.sh`.
- `delete_random_pods.sh` — Bash helper script `delete_random_pods.sh`.
- `drain_node.sh` — Bash helper script `drain_node.sh`.
- `expand_tmp.sh` — Bash helper script `expand_tmp.sh`.
- `oomkill_pod.sh` — Bash helper script `oomkill_pod.sh`.
