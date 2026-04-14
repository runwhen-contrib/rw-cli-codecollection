# Kubernetes StatefulSet Operations

This codebundle provides StatefulSet-scoped operational tasks so operators can restart workloads, recycle pods, roll back, scale replicas, tune HPA bounds, and adjust CPU or memory resources—similar to `k8s-deployment-ops`, but for the StatefulSet API.

## Overview

- **Rollout operations**: rollout restart and rollout undo with optional rollout status wait; failures surface as issues.
- **Pod recycle**: delete pods using the StatefulSet pod template labels and verify pods are recreated.
- **Scaling**: scale down (with `ALLOW_SCALE_TO_ZERO` guard), scale up by a factor capped by `MAX_REPLICAS`.
- **HPA**: scale HPA min or max for an HPA whose `scaleTargetRef` points at this StatefulSet; GitOps-managed HPAs receive suggestions only.
- **Resources**: increase or decrease CPU and memory using VPA upper bounds when present, or proportional changes, with GitOps and HPA conflict avoidance.

ReplicaSet cleanup tasks are not included (not applicable to StatefulSets).

## Configuration

### Required variables

- `CONTEXT`: Kubernetes context to use.
- `NAMESPACE`: Namespace containing the StatefulSet.
- `STATEFULSET_NAME`: Target StatefulSet name.

### Optional variables

- `KUBERNETES_DISTRIBUTION_BINARY`: `kubectl` or `oc` (default: `kubectl`).
- `SCALE_UP_FACTOR`: Multiplier for scale-up tasks (default: `2`).
- `MAX_REPLICAS`: Upper cap for scale-up (default: `10`).
- `ALLOW_SCALE_TO_ZERO`: If `true`, scale-down may set replicas to `0`; if `false`, scale-down targets `1` and emits an informational issue when zero was requested (default: `false`).
- `HPA_SCALE_FACTOR`: Multiplier for HPA min and max during HPA scale-up (default: `2`).
- `HPA_MAX_REPLICAS`: Cap for HPA max replicas during HPA scale-up (default: `20`).
- `HPA_MIN_REPLICAS`: Target min and max for HPA scale-down (default: `1`).
- `RESOURCE_SCALE_DOWN_FACTOR`: Divisor for CPU and memory when decreasing resources (default: `2`).

### Secrets

- `kubeconfig`: Kubernetes kubeconfig YAML for cluster authentication.

## Tasks

### Restart StatefulSet in Namespace

Rollout restart with rollout status wait when restart succeeds; stderr from restart surfaces as issues.

### Force Delete Pods for StatefulSet

Deletes pods selected by labels from the StatefulSet pod template; lists pods afterward. Failures raise issues.

### Rollback StatefulSet to Previous Version

Runs `kubectl rollout undo` for the StatefulSet and waits for rollout status.

### Scale Down StatefulSet

Scales replicas to `0` or `1` depending on `ALLOW_SCALE_TO_ZERO`; blocked zero-scale emits a severity-4 issue.

### Scale Up StatefulSet by Factor

Reads current replicas, multiplies by `SCALE_UP_FACTOR`, caps at `MAX_REPLICAS`, and scales the StatefulSet.

### Scale Up / Scale Down HPA for StatefulSet

Finds an HPA with `scaleTargetRef.kind` StatefulSet and matching name. Respects GitOps by suggesting patches when the HPA is Flux or Argo CD managed.

### Increase / Decrease CPU and Memory Resources for StatefulSet

Uses VPA upper bound when a matching VPA `targetRef` exists for this StatefulSet; otherwise scales requests or limits proportionally. Skips apply when GitOps labels or an HPA targeting this workload suggests manual or coordinated change.

## Requirements

- Network access to the cluster API and RBAC sufficient for the chosen tasks.
- `jq` available in the execution environment for HPA and VPA JSON filtering.
