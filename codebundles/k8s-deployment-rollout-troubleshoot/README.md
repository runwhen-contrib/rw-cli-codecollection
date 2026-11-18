# Kubernetes Deployment Rollout Troubleshoot

Read-only diagnostics for Kubernetes Deployments whose rolling updates are stuck, slow, or failing. This CodeBundle focuses on rollout lifecycle signals—conditions, ReplicaSet state, blocking pods and events, rollout strategy, and PodDisruptionBudget constraints—so operators can quickly determine why a deployment will not reach a successful rollout.

## Overview

- **Rollout status**: Evaluates deployment conditions, replica counts, and `kubectl rollout status` sampling
- **ReplicaSet comparison**: Detects conflicting active ReplicaSets and outdated pods during rollout
- **New ReplicaSet pod failures**: Surfaces Pending, image pull, crash, and readiness failures on the latest revision
- **Rollout strategy**: Reviews RollingUpdate/Recreate settings, progress deadlines, and paused state
- **PDB impact**: Identifies PodDisruptionBudgets that block pod eviction during rollout
- **Blocking events**: Collects recent Warning/Error events on the deployment, ReplicaSets, and pods
- **Stuck terminating pods**: Finds pods stuck in Terminating that block old ReplicaSet scale-down
- **Rollout history**: Summarizes revision history and recent template changes (image, probes, resources)

All tasks are read-only. Remediation belongs in `k8s-deployment-ops`.

## Configuration

### Required Variables

- `CONTEXT`: Kubernetes context to operate within
- `NAMESPACE`: Namespace containing the deployment
- `DEPLOYMENT_NAME`: Name of the deployment to troubleshoot

### Optional Variables

- `KUBERNETES_DISTRIBUTION_BINARY`: Kubernetes CLI binary (`kubectl` or `oc`) (default: `kubectl`)
- `EVENT_AGE`: Lookback window for rollout-related events (default: `30m`)
- `ROLLOUT_STATUS_TIMEOUT`: Seconds to wait when sampling rollout status (default: `30`)
- `STUCK_TERMINATING_THRESHOLD`: Minutes a pod may remain Terminating before raising an issue (default: `5`)

### Secrets

- `kubeconfig`: Standard kubeconfig YAML with RBAC read access to deployments, replicasets, pods, events, and poddisruptionbudgets in the target namespace

## Tasks Overview

### Check Deployment Rollout Status

Evaluates rollout progress via deployment status fields and `kubectl rollout status`. Detects `ProgressDeadlineExceeded`, stalled progressing conditions, and mismatches between desired, updated, available, and ready replica counts.

### Compare Deployment ReplicaSets During Rollout

Compares the latest ReplicaSet against older ReplicaSets owned by the deployment. Flags conflicting active ReplicaSets, outdated pods not on the latest revision, and rollouts where the new ReplicaSet is not receiving traffic.

### Inspect New ReplicaSet Pod Failures

Focuses on pods owned by the latest ReplicaSet that block rollout completion: Pending, CrashLoopBackOff, ImagePullBackOff, ErrImagePull, CreateContainerConfigError, and containers failing readiness after start.

### Check Rollout Strategy Configuration

Reviews deployment update strategy (RollingUpdate vs Recreate), maxUnavailable, maxSurge, progressDeadlineSeconds, revisionHistoryLimit, and paused state. Identifies configurations that can stall or dangerously slow rollouts.

### Check PodDisruptionBudget Impact on Rollout

Finds PDBs whose selectors match the deployment and evaluates whether minAvailable or maxUnavailable constraints prevent eviction of old pods or creation/scheduling of new pods during the rollout.

### Detect Rollout Blocking Events

Surfaces recent Warning/Error events on the deployment, its ReplicaSets, and rollout pods (FailedScheduling, FailedCreate, ReplicaFailure, ProgressDeadlineExceeded, FailedMount, quota/admission failures) within a configurable time window.

### Check Stuck Terminating Pods Blocking Rollout

Identifies deployment pods stuck in Terminating state that prevent old ReplicaSet scale-down and block rollout completion; includes finalizer and node attachment hints.

### Fetch Rollout History

Retrieves rollout revision history and summarizes recent template changes (image, env, probes, resources) to correlate failed rollouts with specific revisions.

## Related CodeBundles

- `k8s-deployment-healthcheck`: General deployment triage (replicas, probes, logs, restarts, HPA)
- `k8s-deployment-ops`: Remediation actions (rollout restart, rollback, scale stale ReplicaSets, force delete pods)
- `k8s-app-troubleshoot`: Deep application log and stacktrace analysis when new ReplicaSet pods fail readiness or crash
- `k8s-argocd-application-health`: GitOps sync/health issues when deployment is ArgoCD-managed
