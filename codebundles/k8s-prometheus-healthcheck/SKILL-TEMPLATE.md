---
name: k8s-prometheus-healthcheck
kind: skill-template
description: This taskset investigates the logs, state and health of Kubernetes Prometheus operator. Use when triaging or monitoring Kubernetes, AKS, EKS workloads with skill template `k8s-prometheus-healthcheck`.
runtime:
  runbook: runbook.robot
  runner: ro
platforms: [Kubernetes, AKS, EKS, GKE, OpenShift, Prometheus]
resource_types: [kubernetes_resource]
access: read-only
---

# Kubeprometheus Operator Troubleshoot

## Summary

A set of tasks that troubleshoot the Kubernetes Prometheus Operator for issues.

See [README.md](README.md) for additional context.

## Tools

### Check Prometheus Service Monitors in namespace `${NAMESPACE}`

Checks the selector mappings of service monitors are valid in the namespace

- **Robot task name**: <code>Check Prometheus Service Monitors in namespace `${NAMESPACE}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `validate_servicemonitors.sh`
- **Tags**: `access:read-only`, `prometheus`, `data:config`
- **Reads**: `NAMESPACE`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Check For Successful Rule Setup in Kubernetes Namespace `${NAMESPACE}`

Inspects operator instance logs for failed rules setup

- **Robot task name**: <code>Check For Successful Rule Setup in Kubernetes Namespace `${NAMESPACE}`</code>
- **Robot file**: `runbook.robot`
- **Tags**: `access:read-only`, `prometheys`, `data:logs-regexp`
- **Reads**: `CONTEXT`, `KUBERNETES_DISTRIBUTION_BINARY`, `NAMESPACE`, `PROM_NAMESPACE`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Verify Prometheus RBAC Can Access ServiceMonitors in Namespace `${PROM_NAMESPACE}`

Fetch operator rbac and verify it has ServiceMonitors in rbac.

- **Robot task name**: <code>Verify Prometheus RBAC Can Access ServiceMonitors in Namespace `${PROM_NAMESPACE}`</code>
- **Robot file**: `runbook.robot`
- **Tags**: `access:read-only`, `prometheus`, `data:config`
- **Reads**: `KUBERNETES_DISTRIBUTION_BINARY`, `PROM_NAMESPACE`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Inspect Prometheus Operator Logs for Scraping Errors in Namespace `${NAMESPACE}`

Inspect the prometheus operator logs for scraping errors and raise issues if any found

- **Robot task name**: <code>Inspect Prometheus Operator Logs for Scraping Errors in Namespace `${NAMESPACE}`</code>
- **Robot file**: `runbook.robot`
- **Tags**: `access:read-only`, `prometheus`, `data:logs-regexp`
- **Reads**: `CONTEXT`, `KUBERNETES_DISTRIBUTION_BINARY`, `NAMESPACE`, `PROM_NAMESPACE`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Check Prometheus API Healthy in Namespace `${PROM_NAMESPACE}`

Ping Prometheus healthy API endpoint for a 200 response code.

- **Robot task name**: <code>Check Prometheus API Healthy in Namespace `${PROM_NAMESPACE}`</code>
- **Robot file**: `runbook.robot`
- **Tags**: `access:read-only`, `prometheus`, `data:config`
- **Reads**: `CONTEXT`, `KUBERNETES_DISTRIBUTION_BINARY`, `NAMESPACE`, `PROM_NAMESPACE`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


## Inputs

| Name | Type | Description | Default | Required |
|---|---|---|---|---|
| `KUBERNETES_DISTRIBUTION_BINARY` | string | Which binary to use for Kubernetes CLI commands. | `kubectl` | no |
| `CONTEXT` | string | Which Kubernetes context to operate within. | — | yes |
| `NAMESPACE` | string | The name of the namespace to search. | `loki` | no |
| `PROM_NAMESPACE` | string | The name of the namespace that kubeprometheus resides in. | `kube-prometheus-stack` | no |

## Secrets

_No secrets imported in Robot source._

## Outputs

_See Robot run output and platform report artifacts._

## How to invoke

### Preferred: Robot Framework runner (`ro`)

```bash
cd codebundles/k8s-prometheus-healthcheck
export KUBERNETES_DISTRIBUTION_BINARY=...
export CONTEXT=...
export NAMESPACE=...
export PROM_NAMESPACE=...
ro runbook.robot
```

### Standalone scripts (no Robot)


Set the input variables above, then run the matching script:

```bash
cd codebundles/k8s-prometheus-healthcheck
export KUBERNETES_DISTRIBUTION_BINARY=...
export CONTEXT=...
export NAMESPACE=...
export PROM_NAMESPACE=...
bash validate_servicemonitors.sh
```

## Source files

- `runbook.robot` — orchestrates tools and raises issues
- `validate_servicemonitors.sh` — Bash helper script `validate_servicemonitors.sh`.
