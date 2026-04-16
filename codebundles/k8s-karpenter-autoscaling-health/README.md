# Kubernetes Karpenter Autoscaling Health

This CodeBundle monitors Karpenter-driven autoscaling: NodePool or legacy Provisioner status, NodeClaim or Machine readiness, Pending workloads that indicate capacity or scheduling pressure, Karpenter controller logs, cloud NodeClass conditions, stuck NodeClaims, and optional log-to-pod correlation.

## Overview

- **NodePool and NodeClaim status**: Parses `status.conditions` for False or Unknown states and summarizes cordoned or NotReady nodes.
- **Pending workloads**: Surfaces Pending pods whose messages suggest insufficient capacity, topology spread, or scheduling timeouts.
- **Controller logs**: Scans recent Karpenter pod logs within `RW_LOOKBACK_WINDOW` for error patterns (capped per pod).
- **NodeClass health**: Reads EC2NodeClass, AWSNodeTemplate, or other provider NodeClass CRDs when installed.
- **Stuck NodeClaims**: Flags claims that stay non-ready past `STUCK_NODECLAIM_THRESHOLD_MINUTES` or show prolonged deletion.
- **Correlation**: Optionally links log lines to Pending pod names for triage.
- **SLI**: `sli.robot` emits a 0–1 score from lightweight kubectl checks (no heavy log tail).

## Configuration

### Required variables

- `CONTEXT`: kubectl context for the cluster under inspection.

### Optional variables (runbook)

- `KARPENTER_NAMESPACE`: Namespace of the Karpenter controller (default: `karpenter`).
- `KUBERNETES_DISTRIBUTION_BINARY`: CLI binary (default: `kubectl`).
- `RW_LOOKBACK_WINDOW`: Log lookback for controller and correlation tasks (default: `30m`).
- `KARPENTER_LOG_ERROR_THRESHOLD`: Minimum matching log lines before raising a log issue (default: `1`).
- `STUCK_NODECLAIM_THRESHOLD_MINUTES`: Age in minutes after which a non-ready NodeClaim is treated as stale (default: `30`).
- `KARPENTER_LOG_MAX_LINES`: Tail cap per controller pod for log tasks (default: `500`).

### Optional variables (SLI only)

- `SLI_PENDING_POD_MAX`: Maximum Pending pods with capacity-like messages before the SLI pending dimension fails (default: `5`).
- `STUCK_NODECLAIM_THRESHOLD_MINUTES`: Same semantics as the runbook; used by the stuck dimension in `sli.robot`.

### Secrets

- `kubeconfig`: Standard kubeconfig with read-only cluster access. Pod log tasks require `get pods` and `logs` in the Karpenter namespace.

## Tasks overview

### Summarize NodePool and NodeClaim Health

Lists NodePools or Provisioners and NodeClaims or Machines (when CRDs exist), evaluates unhealthy conditions, and reports NotReady or cordoned worker nodes.

### Detect Workloads Blocked on Provisioning or Capacity

Finds Pending pods whose aggregated condition messages match common capacity and scheduling failure patterns.

### Scan Karpenter Controller Logs for Errors

Aggregates recent logs from detected controller pods for ERROR, WARN, and cloud-provisioning failure substrings, respecting thresholds and tail limits.

### Check Cloud NodeClass Resources for Misconfiguration Signals

Inspects NodeClass or AWSNodeTemplate conditions; degrades cleanly when provider CRDs are not installed.

### Identify Stale or Stuck NodeClaims

Flags NodeClaims (or legacy Machines) that remain non-ready beyond the threshold or show deletion delays.

### Correlate Recent Karpenter Log Patterns with Pending Pods

When a Pending pod name appears in error-pattern log lines, raises a targeted issue for faster cross-checks.

### SLI: Measure Karpenter Autoscaling Health Score

Computes a mean of three binary dimensions (conditions, Pending pressure, stuck claims) for periodic health scoring.
