---
name: k8s-fluxcd-reconcile
kind: skill-template
description: Generates a report of the reconciliation errors for fluxcd in your cluster. Use when triaging or monitoring Kubernetes, Fluxcd workloads with skill template `k8s-fluxcd-reconcile`.
runtime:
  runbook: runbook.robot
  monitor: sli.robot
  executor: worker
  entrypoint: /home/runwhen/robot-runtime/runrobot.sh
  base_image: rw-base-runtime
platforms: [Kubernetes, Fluxcd]
resource_types: [kubernetes_resource]
access: read-only
---

# Kubernetes Fluxcd Reconciliation Report

## Summary

This codebundle measures the number of reconciliation errors in the fluxcd controllers and can generate a report of them.

See [README.md](README.md) for additional context.

## Tools

### Check FluxCD Reconciliation Health in Kubernetes Namespace `${FLUX_NAMESPACE}`

Fetches reconciliation logs for flux and creates a report for them.

- **Robot task name**: <code>Check FluxCD Reconciliation Health in Kubernetes Namespace `${FLUX_NAMESPACE}`</code>
- **Robot file**: `runbook.robot`
- **Tags**: `access:read-only`, `Kubernetes`, `Namespace`, `Flux`, `data:config`
- **Reads**: —
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


## Monitor

Measures failing reconciliations for fluxcd

- **Robot file**: `sli.robot`
- **Score range**: `0.0` (failing) to `1.0` (healthy)
- **Aggregation**: arithmetic mean of the sub-checks below
- **Recommended interval**: `180s`

### Sub-checks

#### Health Check Flux Reconciliation

Measures failing reconciliations for fluxcd

- **Robot task name**: <code>Health Check Flux Reconciliation</code>
- **Sub-metric name**: `fluxcd_reconcile`
- **Tags**: `Kubernetes`, `Namespace`, `Flux`, `data:config`
- **Reads**: —


## Inputs

| Name | Type | Description | Default | Required |
|---|---|---|---|---|
| `CONTEXT` | string | The kubernetes context to use in the kubeconfig provided. | — | yes |
| `FLUX_NAMESPACE` | string | The namespace where the flux controllers reside. Typically flux-system. | `flux-system` | no |

## Secrets

| Name | Description | Required |
|---|---|---|
| `kubeconfig` | The kubeconfig secret to use for authenticating with the cluster. | yes |

## Outputs

- Monitor health score (`0.0`–`1.0`) pushed by `sli.robot`

## How to invoke

### Production (RunWhen runner / worker)

The platform **runner** schedules work on a location **worker**. The worker
image (`rw-base-runtime`) executes Robot via `runrobot.sh` with
`RW_PATH_TO_ROBOT` set to the bound path under `/home/runwhen/collection/`.

- **Runbook**: `codebundles/k8s-fluxcd-reconcile/runbook.robot`
- **Monitor**: `codebundles/k8s-fluxcd-reconcile/sli.robot`

### Local development (devcontainer only)

`ro` is a dev-time wrapper in `codecollection-devtools` — not the enterprise runtime.

```bash
cd codebundles/k8s-fluxcd-reconcile
export CONTEXT=...
export FLUX_NAMESPACE=...
ro runbook.robot
```

### Standalone scripts (no Robot)


Set the input variables above, then run the matching script:

```bash
cd codebundles/k8s-fluxcd-reconcile
export CONTEXT=...
export FLUX_NAMESPACE=...
bash flux_reconcile_report.sh
```

## Source files

- `runbook.robot` — orchestrates tools and raises issues
- `sli.robot` — monitor scoring (`sli.robot` runtime file)
- `flux_reconcile_report.sh` — Bash helper script `flux_reconcile_report.sh`.
