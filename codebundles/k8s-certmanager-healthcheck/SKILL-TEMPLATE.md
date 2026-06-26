---
name: k8s-certmanager-healthcheck
kind: skill-template
description: Checks the overall health of certificates in a namespace that are managed by cert-manager. Use when triaging or monitoring Kubernetes, AKS, EKS workloads with skill template `k8s-certmanager-health...
runtime:
  runbook: runbook.robot
  monitor: sli.robot
  executor: worker
  entrypoint: /home/runwhen/robot-runtime/runrobot.sh
  base_image: rw-base-runtime
platforms: [Kubernetes, AKS, EKS, GKE, OpenShift, cert-manager]
resource_types: [kubernetes_resource]
access: read-only
---

# Kubernetes cert-manager Healthcheck

## Summary

This taskset looks into issues related to CertManager Certificates.

See [README.md](README.md) for additional context.

## Tools

### Get Namespace Certificate Summary for Namespace `${NAMESPACE}`

Gets a list of cert-manager certificates that are due for renewal and summarize their information for review.

- **Robot task name**: <code>Get Namespace Certificate Summary for Namespace `${NAMESPACE}`</code>
- **Robot file**: `runbook.robot`
- **Tags**: `tls`, `certificates`, `kubernetes`, `objects`, `expiration`, `summary`, `cert-manager`, `data:config`
- **Reads**: `CONTEXT`, `KUBERNETES_DISTRIBUTION_BINARY`, `NAMESPACE`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Find Unhealthy Certificates in Namespace `${NAMESPACE}`

Gets a list of cert-manager certificates are not available.

- **Robot task name**: <code>Find Unhealthy Certificates in Namespace `${NAMESPACE}`</code>
- **Robot file**: `runbook.robot`
- **Tags**: `tls`, `certificates`, `kubernetes`, `cert-manager`, `failed`, `data:config`
- **Reads**: `CONTEXT`, `KUBERNETES_DISTRIBUTION_BINARY`, `NAMESPACE`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Find Failed Certificate Requests and Identify Issues for Namespace `${NAMESPACE}`

Gets a list of failed cert-manager certificates and summarize their issues.

- **Robot task name**: <code>Find Failed Certificate Requests and Identify Issues for Namespace `${NAMESPACE}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `certificate_next_steps.sh`
- **Tags**: —
- **Reads**: `CONTEXT`, `KUBERNETES_DISTRIBUTION_BINARY`, `NAMESPACE`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


## Monitor

Counts the number of unhealthy cert-manager managed certificates in a namespace.

- **Robot file**: `sli.robot`
- **Score range**: `0.0` (failing) to `1.0` (healthy)
- **Aggregation**: arithmetic mean of the sub-checks below
- **Recommended interval**: `180s`

### Sub-checks

#### Count Unready and Expired Certificates in Namespace `${NAMESPACE}`

Adds together the count of unready and expired certificates. A healthy SLI value is 0.

- **Robot task name**: <code>Count Unready and Expired Certificates in Namespace `${NAMESPACE}`</code>
- **Sub-metric name**: `cert_manager_health`
- **Tags**: `certificate`, `status`, `count`, `health`, `certmanager`, `cert`, `data:config`
- **Reads**: `CONTEXT`, `KUBERNETES_DISTRIBUTION_BINARY`, `NAMESPACE`


## Inputs

| Name | Type | Description | Default | Required |
|---|---|---|---|---|
| `KUBERNETES_DISTRIBUTION_BINARY` | string | Which binary to use for Kubernetes CLI commands. | `kubectl` | no |
| `CONTEXT` | string | Which Kubernetes context to operate within. | — | yes |
| `NAMESPACE` | string | The name of the namespace to search. | `` | yes |
| `DISTRIBUTION` | string | Which distribution of Kubernetes to use for operations, such as: Kubernetes, OpenShift, etc. | `Kubernetes` | no |

## Secrets

_No secrets imported in Robot source._

## Outputs

- Monitor health score (`0.0`–`1.0`) pushed by `sli.robot`

## How to invoke

### Production (RunWhen runner / worker)

The platform **runner** schedules work on a location **worker**. The worker
image (`rw-base-runtime`) executes Robot via `runrobot.sh` with
`RW_PATH_TO_ROBOT` set to the bound path under `/home/runwhen/collection/`.

- **Runbook**: `codebundles/k8s-certmanager-healthcheck/runbook.robot`
- **Monitor**: `codebundles/k8s-certmanager-healthcheck/sli.robot`

### Local development (devcontainer only)

`ro` is a dev-time wrapper in `codecollection-devtools` — not the enterprise runtime.

```bash
cd codebundles/k8s-certmanager-healthcheck
export KUBERNETES_DISTRIBUTION_BINARY=...
export CONTEXT=...
export NAMESPACE=...
export DISTRIBUTION=...
ro runbook.robot
```

### Standalone scripts (no Robot)


Set the input variables above, then run the matching script:

```bash
cd codebundles/k8s-certmanager-healthcheck
export KUBERNETES_DISTRIBUTION_BINARY=...
export CONTEXT=...
export NAMESPACE=...
export DISTRIBUTION=...
bash certificate_next_steps.sh
```

## Source files

- `runbook.robot` — orchestrates tools and raises issues
- `sli.robot` — monitor scoring (`sli.robot` runtime file)
- `certificate_next_steps.sh` — Bash helper script `certificate_next_steps.sh`.
