# Kubernetes StatefulSet Operations

This CodeBundle provides safe, repeatable operational actions for Kubernetes StatefulSets: restart, pod recovery, rollback, replica scaling, HPA tuning, and CPU or memory adjustments. It mirrors the operational surface of `k8s-deployment-ops` where semantics apply, without Deployment-only ReplicaSet cleanup tasks.

## Overview

- **Rollout and recovery**: Rollout restart with logs, force-delete pods via StatefulSet pod template labels, and rollout undo with status polling.
- **Scaling**: Scale down (respecting `ALLOW_SCALE_TO_ZERO`), scale up with `SCALE_UP_FACTOR` and `MAX_REPLICAS` caps.
- **HPA**: Scale HPA min or max for an HPA that targets this StatefulSet, with GitOps guardrails.
- **Resources**: Increase or decrease CPU and memory using VPA recommendations when present, or proportional changes, with GitOps and HPA conflict handling.

## Configuration

### Required variables

- `CONTEXT`: Kubernetes context name.
- `NAMESPACE`: Namespace containing the StatefulSet.
- `STATEFULSET_NAME`: Target StatefulSet.

### Optional variables

- `KUBERNETES_DISTRIBUTION_BINARY`: `kubectl` or `oc` (default: `kubectl`).
- `SCALE_UP_FACTOR`: Replica multiplier for scale-up (default: `2`).
- `MAX_REPLICAS`: Ceiling for manual scale-up (default: `10`).
- `ALLOW_SCALE_TO_ZERO`: Whether scale-down may use zero replicas (default: `false`).
- `HPA_SCALE_FACTOR`: Multiplier for HPA min or max when scaling HPA up (default: `2`).
- `HPA_MAX_REPLICAS`: Cap applied to HPA max during HPA scale-up (default: `20`).
- `HPA_MIN_REPLICAS`: Target min and max when scaling HPA down (default: `1`).
- `RESOURCE_SCALE_DOWN_FACTOR`: Divisor for CPU or memory decrease tasks (default: `2`).

### Secrets

- `kubeconfig`: Kubeconfig file content for cluster authentication (YAML).

## Tasks

### Restart StatefulSet

Rollout restart with pre-restart logs and `rollout status`; raises issues on failure.

### Force Delete Pods in StatefulSet

Deletes pods selected using the StatefulSet pod template labels to recover stuck workloads.

### Rollback StatefulSet to Previous Version

`kubectl rollout undo` for the StatefulSet with status polling.

### Scale Down StatefulSet

Scales replicas to `0` or `1` per `ALLOW_SCALE_TO_ZERO`; raises a policy issue when scaling to zero is blocked.

### Scale Up StatefulSet

Multiplies current replicas subject to `MAX_REPLICAS`.

### Scale Up HPA / Scale Down HPA

Finds an HPA whose `scaleTargetRef` is this StatefulSet; applies patches or suggests GitOps manifest updates when managed by Flux or Argo CD.

### Increase or Decrease CPU / Memory Resources

Uses VPA upper bounds when available, otherwise multiplies or divides requests and limits, with GitOps and HPA safeguards.

## Requirements

Kubeconfig and RBAC must allow the intended mutating operations on the StatefulSet, pods, HPA, and (if used) VPA resources in the namespace.
