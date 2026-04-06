# Kubernetes StatefulSet Operations

This CodeBundle provides StatefulSet-scoped operational tasks (restart, pod recycle, rollback, replica scaling, HPA adjustments, and CPU/memory tuning) so operators can run the same class of remediations as deployment-oriented bundles without relying only on label-based restart flows.

## Overview

- **Rollout and pods**: Restart a StatefulSet, force-delete pods using pod template labels, and roll back to a previous revision with rollout status feedback.
- **Scaling**: Scale replicas down (with `ALLOW_SCALE_TO_ZERO` guard) or scale up by a factor capped by `MAX_REPLICAS`.
- **HPA**: Locate an HPA whose `scaleTargetRef` targets this StatefulSet; scale min/max up or toward `HPA_MIN_REPLICAS`, with GitOps-aware suggest-only behavior when appropriate.
- **Resources**: Increase or decrease CPU/memory using VPA upper bounds when present, or proportional changes to current requests/limits, with GitOps and HPA conflict detection.

ReplicaSet cleanup tasks are not included (not applicable to StatefulSets).

## Configuration

### Required variables

- `STATEFULSET_NAME`: Target StatefulSet name.
- `NAMESPACE`: Namespace containing the StatefulSet.
- `CONTEXT`: Kubernetes context to use.

### Optional variables

- `KUBERNETES_DISTRIBUTION_BINARY`: CLI binary (`kubectl` or `oc`, default `kubectl`).
- `SCALE_UP_FACTOR`: Multiplier for scale-up (default `2`).
- `MAX_REPLICAS`: Upper cap for scale-up (default `10`).
- `ALLOW_SCALE_TO_ZERO`: Set to `true` to allow scaling to zero replicas (default `false`).
- `HPA_SCALE_FACTOR`: Multiplier for HPA min/max when scaling HPA up (default `2`).
- `HPA_MAX_REPLICAS`: Cap for HPA max during scale-up (default `20`).
- `HPA_MIN_REPLICAS`: Target min/max floor when scaling HPA down (default `1`).
- `RESOURCE_SCALE_DOWN_FACTOR`: Divisor for CPU/memory when decreasing resources (default `2`).

### Secrets

- `kubeconfig`: Kubernetes kubeconfig YAML for cluster authentication.

## Tasks and capabilities

### Restart StatefulSet in Namespace

Rollout restart with optional rollout status wait; stderr from restart surfaces as issues.

### Force Delete Pods for StatefulSet

Deletes pods selected by the StatefulSet pod template labels and verifies recreation via pod list output.

### Rollback StatefulSet to Previous Version

`kubectl rollout undo` with rollout status polling for ordered recovery.

### Scale Down StatefulSet

Scales replicas down; honors `ALLOW_SCALE_TO_ZERO` and raises an informational issue when scaling to zero is blocked by configuration.

### Scale Up StatefulSet by Factor

Multiplies current replicas by `SCALE_UP_FACTOR`, capped by `MAX_REPLICAS`.

### Scale Up HPA for StatefulSet

Finds HPA with `scaleTargetRef` kind `StatefulSet` matching this workload; GitOps-managed HPAs receive suggestions only.

### Scale Down HPA for StatefulSet

Adjusts HPA min/max toward `HPA_MIN_REPLICAS`; GitOps-aware.

### Increase CPU / Memory Resources for StatefulSet

Uses VPA upper bound when available, otherwise multiplies current requests (and limits when set); skips apply when GitOps or HPA suggests conflict.

### Decrease CPU / Memory Resources for StatefulSet

Divides requests/limits by `RESOURCE_SCALE_DOWN_FACTOR` with CPU millicore and memory Mi floors.

## Requirements

Kubeconfig and RBAC must allow `get`, `patch`, `delete` (pods), and other verbs required for the tasks you run (`kubectl`/`oc` 1.20+ recommended).
