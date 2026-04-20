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

## Local testing

The `.test/` directory is a self-contained harness that exercises every check
script against a throwaway [Kind](https://kind.sigs.k8s.io/) cluster. No AWS
credentials, no real Karpenter controller, and no container-image build are
required — the harness installs:

- **Standalone [KWOK](https://kwok.sigs.k8s.io/)** so fake `Node` objects can
  be driven to Ready/NotReady/cordoned states without real kubelets.
- **Vendored Karpenter CRDs** (`karpenter.sh/NodePool`, `karpenter.sh/NodeClaim`)
  and the **AWS `karpenter.k8s.aws/EC2NodeClass`** schema under
  `kubernetes/crds/`, so the AWS-specific checks have something to inspect.
- **A fake `karpenter` Deployment** whose container emits only INFO
  heartbeats; scenarios overlay additional pods that emit the error patterns
  the log scanner grep's for.

Fixtures patch `.status.conditions` via `kubectl patch --subresource=status`,
so every unhealthy path is exercised deterministically without needing a real
reconciler.

Prerequisites: `kind`, `kubectl`, `jq`, `task` (go-task), and a local Docker
daemon.

```bash
cd .test
task build-infra   # create Kind cluster + install baseline (~90s)
task test-all      # run every scenario (~100s)
task clean         # tear down
```

Or run the whole thing end-to-end with `task default`.

Scenario coverage (each scenario asserts the expected issue titles in the
emitted `*_issues.json`):

| Scenario                        | Check(s) exercised                                 |
| ------------------------------- | -------------------------------------------------- |
| `test-healthy`                  | All checks, asserted empty                         |
| `test-nodepool-unhealthy`       | `check-karpenter-nodepool-nodeclaim-status.sh`     |
| `test-nodeclaim-not-registered` | `check-karpenter-nodepool-nodeclaim-status.sh`     |
| `test-node-not-ready`           | `check-karpenter-nodepool-nodeclaim-status.sh`     |
| `test-node-cordoned`            | `check-karpenter-nodepool-nodeclaim-status.sh`     |
| `test-pending-pod`              | `check-pending-provisioning-workloads.sh`          |
| `test-stuck-nodeclaim`          | `check-stuck-nodeclaims.sh` (threshold=0)          |
| `test-stuck-nodeclaim-deleting` | `check-stuck-nodeclaims.sh` (finalizer + delete)   |
| `test-ec2nodeclass-degraded`    | `check-karpenter-nodeclass-conditions.sh`          |
| `test-controller-logs-errors`   | `scan-karpenter-controller-logs.sh`                |
| `test-log-correlation`          | `correlate-karpenter-logs-pending-pods.sh`         |

Individual scenarios can be run directly, e.g. `task test-pending-pod`.

