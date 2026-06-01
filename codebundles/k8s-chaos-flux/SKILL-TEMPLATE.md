---
name: k8s-chaos-flux
kind: skill-template
description: This taskset is used to suspend a flux resource for the purposes of executing chaos tasks. Use when triaging or monitoring Kubernetes, AKS, EKS workloads with skill template `k8s-chaos-flux`.
runtime:
  runbook: runbook.robot
  runner: ro
platforms: [Kubernetes, AKS, EKS, GKE, OpenShift]
resource_types: [kubernetes_resource]
access: read-write
---

# Kubernetes Flux Choas Testing

## Summary

The `k8s-chaos-flux` codebundle is built to facility chaos tests on Flux managed resources.

See [README.md](README.md) for additional context.

## Tools

### Suspend the Flux Resource Reconciliation for `${FLUX_RESOURCE_NAME}` in namespace `${FLUX_RESOURCE_NAMESPACE}`

Suspends a flux resource so that it can be manipulated for chaos purposes.

- **Robot task name**: <code>Suspend the Flux Resource Reconciliation for `${FLUX_RESOURCE_NAME}` in namespace `${FLUX_RESOURCE_NAMESPACE}`</code>
- **Robot file**: `runbook.robot`
- **Tags**: `Chaos`, `Flux`, `Kubernetes`, `Resource`, `Suspend`, `access:read-write`
- **Reads**: `CONTEXT`, `FLUX_RESOURCE_NAME`, `FLUX_RESOURCE_NAMESPACE`, `FLUX_RESOURCE_TYPE`, `KUBERNETES_DISTRIBUTION_BINARY`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Select Random FluxCD Workload for Chaos Target in Namespace `${FLUX_RESOURCE_NAMESPACE}`

Inspects the Flux resource and randomly selects a deployment to tickle. Tehe. Only runs if RANDOMIZE = Yes.

- **Robot task name**: <code>Select Random FluxCD Workload for Chaos Target in Namespace `${FLUX_RESOURCE_NAMESPACE}`</code>
- **Robot file**: `runbook.robot`
- **Tags**: `Chaos`, `Flux`, `Kubernetes`, `Resource`, `Random`, `access:read-write`
- **Reads**: `CONTEXT`, `FLUX_RESOURCE_NAME`, `KUBERNETES_DISTRIBUTION_BINARY`, `RANDOMIZE`, `TARGET_NAMESPACE`, `TARGET_RESOURCE`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Execute Chaos Command on `${TARGET_RESOURCE}` in Namespace `${TARGET_NAMESPACE}`

Run the desired chaos command within a targeted resource

- **Robot task name**: <code>Execute Chaos Command on `${TARGET_RESOURCE}` in Namespace `${TARGET_NAMESPACE}`</code>
- **Robot file**: `runbook.robot`
- **Tags**: `Chaos`, `Flux`, `Kubernetes`, `Resource`, `Kill`, `OOM`, `access:read-write`
- **Reads**: `CHAOS_COMMAND`, `CHAOS_COMMAND_LOOP`, `CONTEXT`, `KUBERNETES_DISTRIBUTION_BINARY`, `TARGET_NAMESPACE`, `TARGET_RESOURCE`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Execute Additional Chaos Command on ${FLUX_RESOURCE_TYPE} '${FLUX_RESOURCE_NAME}' in namespace '${FLUX_RESOURCE_NAMESPACE}'

Run the additional command as input, verbatim.

- **Robot task name**: <code>Execute Additional Chaos Command on ${FLUX_RESOURCE_TYPE} '${FLUX_RESOURCE_NAME}' in namespace '${FLUX_RESOURCE_NAMESPACE}'</code>
- **Robot file**: `runbook.robot`
- **Tags**: `Chaos`, `Flux`, `Kubernetes`, `Resource`, `access:read-write`
- **Reads**: `ADDNL_COMMAND`, `CONTEXT`, `TARGET_NAMESPACE`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Resume Flux Resource Reconciliation in `${TARGET_NAMESPACE}`

Resumes Flux reconciliation on desired resource.

- **Robot task name**: <code>Resume Flux Resource Reconciliation in `${TARGET_NAMESPACE}`</code>
- **Robot file**: `runbook.robot`
- **Tags**: `Chaos`, `Flux`, `Kubernetes`, `Resource`, `Resume`, `access:read-write`
- **Reads**: `CONTEXT`, `FLUX_RESOURCE_NAME`, `FLUX_RESOURCE_NAMESPACE`, `FLUX_RESOURCE_TYPE`, `KUBERNETES_DISTRIBUTION_BINARY`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


## Inputs

| Name | Type | Description | Default | Required |
|---|---|---|---|---|
| `KUBERNETES_DISTRIBUTION_BINARY` | string | Which binary to use for Kubernetes CLI commands. | `kubectl` | no |
| `CONTEXT` | string | Which Kubernetes context to operate within. | — | yes |
| `RANDOMIZE` | string | Boolean to determine whether to randomly select the impacted resource. | `No` | no |
| `FLUX_RESOURCE_TYPE` | string | The type of the Flux resource to suspend. | `kustomization` | no |
| `FLUX_RESOURCE_NAME` | string | The name of the Flux resource to suspend. | `app-online-boutique` | no |
| `FLUX_RESOURCE_NAMESPACE` | string | The name of the namespace that manages the Flux resource. | `flux-system` | no |
| `TARGET_NAMESPACE` | string | The name of the namespace to target when invoking resource instability. | `online-boutique` | no |
| `TARGET_RESOURCE` | string | The name of the target resource to run chaos commands in. | `deployment/cartservice` | no |
| `CHAOS_COMMAND` | string | The command to run in the target pod. | `/bin/sh -c "while true; do yes > /dev/null & done"` | no |
| `CHAOS_COMMAND_LOOP` | string | The number of times to execute this command. | `1` | no |
| `ADDNL_COMMAND` | string | Run any additional chaos command - verbatim. | `kubectl get pods` | no |

## Secrets

_No secrets imported in Robot source._

## Outputs

_See Robot run output and platform report artifacts._

## How to invoke

### Preferred: Robot Framework runner (`ro`)

```bash
cd codebundles/k8s-chaos-flux
export KUBERNETES_DISTRIBUTION_BINARY=...
export CONTEXT=...
export RANDOMIZE=...
export FLUX_RESOURCE_TYPE=...
export FLUX_RESOURCE_NAME=...
export FLUX_RESOURCE_NAMESPACE=...
ro runbook.robot
```

### Standalone scripts (no Robot)


_No standalone shell scripts in this bundle._

## Source files

- `runbook.robot` — orchestrates tools and raises issues
