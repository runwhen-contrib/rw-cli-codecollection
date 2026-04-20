# Kubernetes Karpenter Control Plane Health

This CodeBundle answers whether the Karpenter controller is running and wired correctly—workload readiness, admission webhooks, recent Warning events, installed CRD groups, and metrics-oriented Services—before you dig into provisioning or node claims.

## Overview

- **Controller workloads**: Discovers Karpenter pods via common Helm labels or name patterns; flags CrashLoopBackOff, missing Ready state, high restarts, and Deployment replica gaps.
- **Admission webhooks**: Reviews ValidatingWebhookConfiguration and MutatingWebhookConfiguration objects tied to Karpenter for TLS/client configuration and recent webhook-related warnings.
- **Warning events**: Groups namespace Warning events in the lookback window for Karpenter-related objects or messages.
- **CRDs**: Lists `karpenter` API groups to detect missing installs or an unusually large mix of groups.
- **Services / metrics**: Confirms Karpenter Services expose likely metrics ports and have Endpoint addresses.

## Configuration

### Required variables

- `CONTEXT`: kubectl context for the cluster being checked.

### Optional variables

- `KARPENTER_NAMESPACE`: Namespace where the controller runs (default: `karpenter`).
- `KUBERNETES_DISTRIBUTION_BINARY`: kubectl-compatible CLI (default: `kubectl`).
- `RW_LOOKBACK_WINDOW`: Window for event-oriented checks, for example `30m` or `2h` (default: `30m`).

### SLI variables

- `SLI_WARNING_EVENT_THRESHOLD`: Maximum number of Warning events in `RW_LOOKBACK_WINDOW` before the SLI warning dimension scores `0` (default: `5`).

### Secrets

- `kubeconfig`: Standard kubeconfig file with read-only cluster access.

## Tasks overview

### Check Karpenter Controller Workload Health in Cluster

Inspects controller pods and related Deployments for readiness, CrashLoopBackOff, elevated restarts, and replica skew.

### Verify Karpenter Admission Webhooks in Cluster

Surfaces webhook configurations that reference the Karpenter namespace and common TLS gaps, plus recent Warning events that mention webhook failures.

### Inspect Warning Events in Karpenter Namespace

Aggregates filtered Warning events (Karpenter workload names or messages) grouped by involved object.

### Summarize Installed Karpenter API Versions and CRDs in Cluster

Enumerates CRD groups matching `karpenter` to validate installation and call out many coexisting API families.

### Check Karpenter Service and Metrics Endpoints in Namespace

Validates Services associated with Karpenter expose endpoints and ports suitable for metrics scraping.

## Local testing

The `.test/` directory contains a self-contained harness for exercising every
check script against a throwaway [Kind](https://kind.sigs.k8s.io/) cluster. It
needs no AWS/EKS/GCP/Azure credentials and no Karpenter build — fixtures apply
raw Kubernetes objects (vendored CRDs, fake controller Deployment, webhook
configs, stand-in Services, and synthetic Warning events) that drive each
check down a known-good or known-bad path.

Prerequisites (devcontainer-installable): `kind`, `kubectl`, `jq`, `task` (go-
task), and a local Docker daemon.

```bash
cd .test
task build-infra   # create Kind cluster + install baseline (~90s)
task test-all      # run every scenario (~70s)
task clean         # tear down
```

Or run the whole thing end-to-end with `task default`.

Scenario coverage (each scenario asserts the expected issue titles in the
emitted `*_issues.json`):

| Scenario                  | Check(s) exercised                             |
| ------------------------- | ---------------------------------------------- |
| `test-healthy`            | All checks, asserted empty                     |
| `test-crashloop`          | `check-karpenter-controller-pods.sh`           |
| `test-replica-gap`        | `check-karpenter-controller-pods.sh`           |
| `test-broken-webhook`     | `check-karpenter-webhooks.sh`                  |
| `test-url-webhook-no-ca`  | `check-karpenter-webhooks.sh`                  |
| `test-extra-crd-groups`   | `check-karpenter-crds.sh`                      |
| `test-warning-events`     | `karpenter-namespace-warning-events.sh` and webhook events |
| `test-svc-no-endpoints`   | `check-karpenter-service-metrics.sh`           |
| `test-svc-no-metrics-port`| `check-karpenter-service-metrics.sh`           |

Individual scenarios can be run directly, e.g. `task test-broken-webhook`.

