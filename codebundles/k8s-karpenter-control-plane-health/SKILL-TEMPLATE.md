---
name: k8s-karpenter-control-plane-health
kind: skill-template
description: Monitors Karpenter controller health: workload readiness, admission webhooks, warning events, CRD versions, and... Use when triaging or monitoring Kubernetes, Karpenter, cluster workloads with skil...
runtime:
  runbook: runbook.robot
  monitor: sli.robot
  runner: ro
platforms: [Kubernetes, Karpenter, cluster, control-plane, health]
resource_types: [kubernetes_resource]
access: read-only
---

# Kubernetes Karpenter Control Plane Health

## Summary

This CodeBundle answers whether the Karpenter controller is running and wired correctly—workload readiness, admission webhooks, recent Warning events, installed CRD groups, and metrics-oriented Services—before you dig into provisioning or node claims.

See [README.md](README.md) for additional context.

## Tools

### Check Karpenter Controller Workload Health in Cluster `${CONTEXT}`

Verifies Karpenter controller pods are Ready, surfaces CrashLoopBackOff, high restarts, and replica gaps for Karpenter Deployments.

- **Robot task name**: <code>Check Karpenter Controller Workload Health in Cluster `${CONTEXT}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `check-karpenter-controller-pods.sh`
- **Tags**: `Kubernetes`, `Karpenter`, `access:read-only`, `data:config`
- **Reads**: `CONTEXT`, `KARPENTER_NAMESPACE`
- **Writes**: `controller_pods_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Verify Karpenter Admission Webhooks in Cluster `${CONTEXT}`

Lists ValidatingWebhookConfiguration and MutatingWebhookConfiguration objects tied to Karpenter and checks TLS client configuration and recent webhook-related warnings.

- **Robot task name**: <code>Verify Karpenter Admission Webhooks in Cluster `${CONTEXT}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `check-karpenter-webhooks.sh`
- **Tags**: `Kubernetes`, `Karpenter`, `webhooks`, `access:read-only`, `data:config`
- **Reads**: `CONTEXT`, `KARPENTER_NAMESPACE`
- **Writes**: `webhook_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Inspect Warning Events in Karpenter Namespace `${KARPENTER_NAMESPACE}`

Aggregates recent Warning events involving Karpenter workloads or messages, grouped by involved object for triage.

- **Robot task name**: <code>Inspect Warning Events in Karpenter Namespace `${KARPENTER_NAMESPACE}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `karpenter-namespace-warning-events.sh`
- **Tags**: `Kubernetes`, `Karpenter`, `events`, `access:read-only`, `data:events`
- **Reads**: `CONTEXT`, `KARPENTER_NAMESPACE`, `RW_LOOKBACK_WINDOW`
- **Writes**: `warning_events_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Summarize Installed Karpenter API Versions and CRDs in Cluster `${CONTEXT}`

Detects CRD API groups related to Karpenter to spot missing installs or mixed API families.

- **Robot task name**: <code>Summarize Installed Karpenter API Versions and CRDs in Cluster `${CONTEXT}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `check-karpenter-crds.sh`
- **Tags**: `Kubernetes`, `Karpenter`, `crd`, `access:read-only`, `data:config`
- **Reads**: `CONTEXT`
- **Writes**: `crds_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Check Karpenter Service and Metrics Endpoints in Namespace `${KARPENTER_NAMESPACE}`

Validates Services that front the controller expose ports suitable for metrics scraping and that Endpoints are populated.

- **Robot task name**: <code>Check Karpenter Service and Metrics Endpoints in Namespace `${KARPENTER_NAMESPACE}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `check-karpenter-service-metrics.sh`
- **Tags**: `Kubernetes`, `Karpenter`, `metrics`, `access:read-only`, `data:metrics`
- **Reads**: `CONTEXT`, `KARPENTER_NAMESPACE`
- **Writes**: `service_metrics_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


## Monitor

Measures Karpenter control-plane health using lightweight controller readiness, webhook presence, warning event volume, and Service endpoint checks. Produces a value between 0 (failing) and 1 (healthy).

- **Robot file**: `sli.robot`
- **Score range**: `0.0` (failing) to `1.0` (healthy)
- **Aggregation**: arithmetic mean of the sub-checks below
- **Recommended interval**: `180s`

### Sub-checks

#### Score Karpenter Control Plane Dimensions in Cluster `${CONTEXT}`

Runs a compact bash probe that returns binary scores per dimension and aggregates them into the SLI metric.

- **Robot task name**: <code>Score Karpenter Control Plane Dimensions in Cluster `${CONTEXT}`</code>
- **Sub-metric name**: `controller`
- **Underlying script**: `sli-karpenter-dimensions.sh`
- **Tags**: `access:read-only`, `data:config`
- **Reads**: —


## Inputs

| Name | Type | Description | Default | Required |
|---|---|---|---|---|
| `CONTEXT` | string | Kubernetes context name for the target cluster. | — | yes |
| `KARPENTER_NAMESPACE` | string | Namespace where the Karpenter controller runs. | `karpenter` | no |
| `KUBERNETES_DISTRIBUTION_BINARY` | string | kubectl-compatible CLI binary. | `kubectl` | no |
| `RW_LOOKBACK_WINDOW` | string | Lookback window for event analysis (for example 30m or 2h). | `30m` | no |
| `SLI_WARNING_EVENT_THRESHOLD` | string | Maximum Warning events allowed in the lookback window for a passing score. | `5` | no |

## Secrets

_No secrets imported in Robot source._

## Outputs

- Monitor health score (`0.0`–`1.0`) pushed by `sli.robot`
- `controller_pods_issues.json`
- `webhook_issues.json`
- `warning_events_issues.json`
- `crds_issues.json`
- `service_metrics_issues.json`

## How to invoke

### Preferred: Robot Framework runner (`ro`)

```bash
cd codebundles/k8s-karpenter-control-plane-health
export CONTEXT=...
export KARPENTER_NAMESPACE=...
export KUBERNETES_DISTRIBUTION_BINARY=...
export RW_LOOKBACK_WINDOW=...
export SLI_WARNING_EVENT_THRESHOLD=...
ro runbook.robot
```

### Standalone scripts (no Robot)


Set the input variables above, then run the matching script:

```bash
cd codebundles/k8s-karpenter-control-plane-health
export CONTEXT=...
export KARPENTER_NAMESPACE=...
export KUBERNETES_DISTRIBUTION_BINARY=...
export RW_LOOKBACK_WINDOW=...
bash check-karpenter-controller-pods.sh
bash check-karpenter-crds.sh
bash check-karpenter-service-metrics.sh
bash check-karpenter-webhooks.sh
bash karpenter-namespace-warning-events.sh
bash sli-karpenter-dimensions.sh
```

## Source files

- `runbook.robot` — orchestrates tools and raises issues
- `sli.robot` — monitor scoring (`sli.robot` runtime file)
- `check-karpenter-controller-pods.sh` — Bash helper script `check-karpenter-controller-pods.sh`.
- `check-karpenter-crds.sh` — Bash helper script `check-karpenter-crds.sh`.
- `check-karpenter-service-metrics.sh` — Bash helper script `check-karpenter-service-metrics.sh`.
- `check-karpenter-webhooks.sh` — Bash helper script `check-karpenter-webhooks.sh`.
- `karpenter-namespace-warning-events.sh` — Bash helper script `karpenter-namespace-warning-events.sh`.
- `sli-karpenter-dimensions.sh` — Bash helper script `sli-karpenter-dimensions.sh`.
