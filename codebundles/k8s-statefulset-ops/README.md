# Kubernetes StatefulSet Operations

This CodeBundle provides StatefulSet-scoped operational tasks (restart, pod recycle, rollback, replica scaling, HPA adjustment, and CPU/memory tuning) so operators can run the same class of remediations as `k8s-deployment-ops` for workloads backed by the StatefulSet API.

## Overview

- **Rollouts**: Rollout restart and rollback with optional rollout status wait; failures surface as issues.
- **Pods**: Force-delete pods using the StatefulSet pod template labels and verify recreation.
- **Scale**: Scale down (with `ALLOW_SCALE_TO_ZERO` guard), scale up by a factor with `MAX_REPLICAS` cap.
- **HPA**: Scale HPA min/max when an HPA targets this StatefulSet (`scaleTargetRef.kind` StatefulSet); GitOps-aware suggestions when labels/annotations indicate Flux/ArgoCD.
- **Resources**: Increase or decrease CPU/memory using VPA upper bound when present, or scale from current requests/limits; skips apply when GitOps or HPA suggests conflict (suggestion-only).

ReplicaSet cleanup tasks from `k8s-deployment-ops` are intentionally omitted (not applicable to StatefulSets).

## Configuration

### Required variables

- `CONTEXT`: Kubernetes context to use.
- `NAMESPACE`: Namespace containing the StatefulSet.
- `STATEFULSET_NAME`: Target StatefulSet name.
- `kubeconfig` (secret): Kubeconfig YAML for cluster authentication.

### Optional variables

- `KUBERNETES_DISTRIBUTION_BINARY`: `kubectl` or `oc` (default: `kubectl`).
- `SCALE_UP_FACTOR`: Multiplier for scale-up-by-factor task (default: `2`).
- `MAX_REPLICAS`: Upper cap for scale-up (default: `10`).
- `ALLOW_SCALE_TO_ZERO`: Allow scaling replicas to `0` on scale-down (default: `false`).
- `HPA_SCALE_FACTOR`: Multiplier for HPA min/max on scale-up (default: `2`).
- `HPA_MAX_REPLICAS`: Cap for HPA max during scale-up (default: `20`).
- `HPA_MIN_REPLICAS`: Target min/max floor for HPA scale-down task (default: `1`).
- `RESOURCE_SCALE_DOWN_FACTOR`: Divisor for CPU/memory decrease tasks (default: `2`).

### Secrets

- `kubeconfig`: Kubernetes kubeconfig in YAML form.

## Tasks

### Restart StatefulSet in Namespace

Rollout restart with rollout status wait when restart succeeds; stderr from restart surfaces as a severity-3 issue.

### Force Delete Pods for StatefulSet

Deletes pods selected by the StatefulSet pod template labels; lists pods after delete when stderr is empty; failures raise issues.

### Rollback StatefulSet to Previous Version

`kubectl rollout undo` with rollout status loop; failures raise issues.

### Scale Down StatefulSet

Scales replicas to `0` when `ALLOW_SCALE_TO_ZERO` is true; otherwise scales to `1` and emits a severity-4 issue about scaling to zero not being permitted. Scale command failures raise issues.

### Scale Up StatefulSet by Factor

Multiplies current replicas by `SCALE_UP_FACTOR` (minimum 1), capped by `MAX_REPLICAS`.

### Scale Up / Scale Down HPA for StatefulSet

Finds an HPA whose `scaleTargetRef` names this StatefulSet and uses kind `StatefulSet`. GitOps-managed HPAs receive patch suggestions only; otherwise applies patches. Missing HPA yields a severity-3 issue.

### Increase / Decrease CPU and Memory Resources for StatefulSet

Adjusts requests/limits via `kubectl set resources` when not blocked by GitOps or HPA (those paths are suggestion-only). VPA upper bound is preferred when a matching VPA targets this StatefulSet. Decrease tasks apply CPU floor (10m) and memory floor (16Mi) after division by `RESOURCE_SCALE_DOWN_FACTOR`.

## Requirements

Kubeconfig and RBAC sufficient for the desired mutating operations on the target namespace.
