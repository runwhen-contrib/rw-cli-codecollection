---
name: k8s-pvc-healthcheck
description: This taskset collects information about storage such as PersistentVolumes and PersistentVolumeClaims to. Use when triaging or monitoring Kubernetes, AKS, EKS workloads with skill template `k8s-pvc-...
runtime:
  runbook: runbook.robot
  monitor: sli.robot
  runner: ro
platforms: [Kubernetes, AKS, EKS, GKE, OpenShift]
resource_types: [persistent_volume_claim]
access: read-only
---

# Kubernetes Persistent Volume Healthcheck

## Summary

This taskset provides a set of commands to troubleshoot storage-related issues in a Kubernetes cluster.

See [README.md](README.md) for additional context.

## Tools

### Fetch Events for Unhealthy Kubernetes PersistentVolumeClaims in Namespace `${NAMESPACE}`

Lists events related to PersistentVolumeClaims within the namespace that are not bound to PersistentVolumes.

- **Robot task name**: <code>Fetch Events for Unhealthy Kubernetes PersistentVolumeClaims in Namespace `${NAMESPACE}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `storage_next_steps.sh`
- **Tags**: `access:read-only`, `pvc`, `list`, `kubernetes`, `storage`, `persistentvolumeclaim`, `persistentvolumeclaims`, `events`, `data:config`
- **Reads**: `CONTEXT`, `KUBERNETES_DISTRIBUTION_BINARY`, `NAMESPACE`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### List PersistentVolumeClaims in Terminating State in Namespace `${NAMESPACE}`

Lists persistentvolumeclaims in a Terminating state.

- **Robot task name**: <code>List PersistentVolumeClaims in Terminating State in Namespace `${NAMESPACE}`</code>
- **Robot file**: `runbook.robot`
- **Tags**: `access:read-only`, `pvc`, `list`, `kubernetes`, `storage`, `persistentvolumeclaim`, `terminating`, `check`, `PersistentVolumes`, `data:config`
- **Reads**: `CONTEXT`, `KUBERNETES_DISTRIBUTION_BINARY`, `NAMESPACE`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### List PersistentVolumes in Terminating State in Namespace `${NAMESPACE}`

Lists events related to persistent volumes in Terminating state.

- **Robot task name**: <code>List PersistentVolumes in Terminating State in Namespace `${NAMESPACE}`</code>
- **Robot file**: `runbook.robot`
- **Tags**: `access:read-only`, `pv`, `list`, `kubernetes`, `storage`, `persistentvolume`, `terminating`, `events`, `data:config`
- **Reads**: `CONTEXT`, `KUBERNETES_DISTRIBUTION_BINARY`, `NAMESPACE`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### List Pods with Attached Volumes and Related PersistentVolume Details in Namespace `${NAMESPACE}`

For each pod in a namespace, collect details on configured PersistentVolumeClaim, PersistentVolume, and node.

- **Robot task name**: <code>List Pods with Attached Volumes and Related PersistentVolume Details in Namespace `${NAMESPACE}`</code>
- **Robot file**: `runbook.robot`
- **Tags**: `access:read-only`, `pod`, `storage`, `pvc`, `pv`, `status`, `csi`, `storagereport`, `data:config`
- **Reads**: `CONTEXT`, `KUBERNETES_DISTRIBUTION_BINARY`, `NAMESPACE`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Fetch the Storage Utilization for PVC Mounts in Namespace `${NAMESPACE}`

For each pod in a namespace, fetch the utilization of any PersistentVolumeClaims mounted using the linux df command. Requires kubectl exec permissions.

- **Robot task name**: <code>Fetch the Storage Utilization for PVC Mounts in Namespace `${NAMESPACE}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `pvc_utilization_check.sh`
- **Tags**: `access:read-only`, `pod`, `storage`, `pvc`, `utilization`, `capacity`, `persistentvolumeclaims`, `persistentvolumeclaim`, `check`, `pvc`, `data:config`
- **Reads**: `CONTEXT`, `KUBERNETES_DISTRIBUTION_BINARY`, `NAMESPACE`
- **Writes**: `pvc_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Check for RWO Persistent Volume Node Attachment Issues in Namespace `${NAMESPACE}`

For each pod in a namespace, check if it has an RWO persistent volume claim and if so, validate that the pod and the pv are on the same node.

- **Robot task name**: <code>Check for RWO Persistent Volume Node Attachment Issues in Namespace `${NAMESPACE}`</code>
- **Robot file**: `runbook.robot`
- **Tags**: `access:read-only`, `pod`, `storage`, `pvc`, `readwriteonce`, `node`, `persistentvolumeclaims`, `persistentvolumeclaim`, `scheduled`, `attachment`, `data:config`
- **Reads**: `CONTEXT`, `KUBERNETES_DISTRIBUTION_BINARY`, `NAMESPACE`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


## Monitor

This SLI collects information about storage such as PersistentVolumes and PersistentVolumeClaims and generates an aggregated health score for the namespace. 1 = Healthy, 0 = Failed, >0 <1 = Degraded

- **Robot file**: `sli.robot`
- **Score range**: `0.0` (failing) to `1.0` (healthy)
- **Aggregation**: arithmetic mean of the sub-checks below
- **Recommended interval**: `180s`

### Sub-checks

#### Generate Namespace Score for Namespace `${NAMESPACE}`

_No sub-check documentation in Robot source._

- **Robot task name**: <code>Generate Namespace Score for Namespace `${NAMESPACE}`</code>
- **Sub-metric name**: `pvc_health`
- **Tags**: —
- **Reads**: —


## Inputs

| Name | Type | Description | Default | Required |
|---|---|---|---|---|
| `KUBERNETES_DISTRIBUTION_BINARY` | string | Which binary to use for Kubernetes CLI commands. | `kubectl` | no |
| `CONTEXT` | string | Which Kubernetes context to operate within. | — | yes |
| `NAMESPACE` | string | The name of the namespace to search. | `` | yes |

## Secrets

_No secrets imported in Robot source._

## Outputs

- Monitor health score (`0.0`–`1.0`) pushed by `sli.robot`
- `pvc_issues.json`

## How to invoke

### Preferred: Robot Framework runner (`ro`)

```bash
cd codebundles/k8s-pvc-healthcheck
export KUBERNETES_DISTRIBUTION_BINARY=...
export CONTEXT=...
export NAMESPACE=...
ro runbook.robot
```

### Standalone scripts (no Robot)


Set the input variables above, then run the matching script:

```bash
cd codebundles/k8s-pvc-healthcheck
export KUBERNETES_DISTRIBUTION_BINARY=...
export CONTEXT=...
export NAMESPACE=...
bash pvc_utilization_check.sh
bash storage_next_steps.sh
```

## Source files

- `runbook.robot` — orchestrates tools and raises issues
- `sli.robot` — monitor scoring (`sli.robot` runtime file)
- `pvc_utilization_check.sh` — Bash helper script `pvc_utilization_check.sh`.
- `storage_next_steps.sh` — Bash helper script `storage_next_steps.sh`.
