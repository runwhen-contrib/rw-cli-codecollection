---
name: k8s-istio-system-health
kind: skill-template
description: Checks istio proxy sidecar injection status, high memory and cpu usage, warnings and errors in logs, valid... Use when triaging or monitoring Kubernetes, Istio, AKS workloads with skill template `k...
runtime:
  runbook: runbook.robot
  monitor: sli.robot
  executor: worker
  entrypoint: /home/runwhen/robot-runtime/runrobot.sh
  base_image: rw-base-runtime
platforms: [Kubernetes, Istio, AKS, EKS, GKE, OpenShift]
resource_types: [kubernetes_resource]
access: read-only
---

# Kubernetes Istio System Health

## Summary

This codebundle provides a task aimed at finding issues related to a Istio sidecar being available for the applications.

See [README.md](README.md) for additional context.

## Tools

### Verify Istio Sidecar Injection for Cluster `${CONTEXT}`

Checks all deployments in specified namespaces for Istio sidecar injection status

- **Robot task name**: <code>Verify Istio Sidecar Injection for Cluster `${CONTEXT}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `istio_sidecar_injection_report.sh`
- **Tags**: —
- **Reads**: —
- **Writes**: `issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Check Istio Sidecar Resource Usage for Cluster `${CONTEXT}`

Checks all pods in specified namespaces for Istio sidecar resources usage

- **Robot task name**: <code>Check Istio Sidecar Resource Usage for Cluster `${CONTEXT}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `istio_sidecar_resource_usage.sh`
- **Tags**: —
- **Reads**: —
- **Writes**: `istio_sidecar_resource_usage_issue.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Validate Istio Installation in Cluster `${CONTEXT}`

Verify Istio Istallation in cluster

- **Robot task name**: <code>Validate Istio Installation in Cluster `${CONTEXT}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `istio_installation_verify.sh`
- **Tags**: —
- **Reads**: —
- **Writes**: `istio_installation_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Check Istio Controlplane Logs For Errors in Cluster `${CONTEXT}`

Check istio controlplane logs for known errors and warnings in cluster ${CONTEXT}

- **Robot task name**: <code>Check Istio Controlplane Logs For Errors in Cluster `${CONTEXT}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `istio_controlplane_logs.sh`
- **Tags**: —
- **Reads**: `CONTEXT`
- **Writes**: `istio_controlplane_issues.json`, `istio_controlplane_report.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Fetch Istio Proxy Logs in Cluster `${CONTEXT}`

Check istio proxy logs for known errors and warnings in cluster

- **Robot task name**: <code>Fetch Istio Proxy Logs in Cluster `${CONTEXT}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `istio_proxy_logs.sh`
- **Tags**: —
- **Reads**: —
- **Writes**: `istio_proxy_issues.json`, `istio_proxy_report.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Verify Istio SSL Certificates in Cluster `${CONTEXT}`

Check Istio valid Root CA and mTLS Certificates in cluster

- **Robot task name**: <code>Verify Istio SSL Certificates in Cluster `${CONTEXT}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `istio_mtls_check.sh`
- **Tags**: —
- **Reads**: —
- **Writes**: `istio_mtls_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Check Istio Configuration Health in Cluster `${CONTEXT}`

Check Istio configurations in cluster

- **Robot task name**: <code>Check Istio Configuration Health in Cluster `${CONTEXT}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `analyze_istio_configurations.sh`
- **Tags**: —
- **Reads**: —
- **Writes**: `issues_istio_analyze.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


## Monitor

Checks istio proxy sidecar injection status, high memory and cpu usage, warnings and errors in logs, valid certificates, configuration and verify istio installation.

- **Robot file**: `sli.robot`
- **Score range**: `0.0` (failing) to `1.0` (healthy)
- **Aggregation**: arithmetic mean of the sub-checks below
- **Recommended interval**: `180s`

### Sub-checks

#### Verify Istio Sidecar Injection for Cluster `${CONTEXT}`

Checks all deployments in specified namespaces for Istio sidecar injection status

- **Robot task name**: <code>Verify Istio Sidecar Injection for Cluster `${CONTEXT}`</code>
- **Sub-metric name**: `sidecar_injection`
- **Underlying script**: `check_istio_injection.sh`
- **Tags**: —
- **Reads**: —
- **Pass condition**: `len(@{issues}) == 0`


#### Check Istio Sidecar Resource Usage for Cluster `${CONTEXT}`

Checks all pods in specified namespaces for Istio sidecar resources usage

- **Robot task name**: <code>Check Istio Sidecar Resource Usage for Cluster `${CONTEXT}`</code>
- **Sub-metric name**: `sidecar_resources`
- **Underlying script**: `istio_sidecar_resource_usage.sh`
- **Tags**: —
- **Reads**: —
- **Pass condition**: `len(@{issues}) == 0`


#### Validate Istio Installation in Cluster `${CONTEXT}`

Verify Istio Istallation

- **Robot task name**: <code>Validate Istio Installation in Cluster `${CONTEXT}`</code>
- **Sub-metric name**: `installation`
- **Underlying script**: `istio_installation_verify.sh`
- **Tags**: —
- **Reads**: —
- **Pass condition**: `len(@{issues}) == 0`


#### Check Istio Controlplane Logs For Errors in Cluster `${CONTEXT}`

Check controlplane logs for known errors and warnings in Cluster

- **Robot task name**: <code>Check Istio Controlplane Logs For Errors in Cluster `${CONTEXT}`</code>
- **Sub-metric name**: `controlplane_logs`
- **Underlying script**: `istio_controlplane_logs.sh`
- **Tags**: —
- **Reads**: —
- **Pass condition**: `len(@{issues}) == 0`


#### Fetch Istio Proxy Logs in Cluster `${CONTEXT}`

Check istio proxy logs for known errors and warnings in cluster

- **Robot task name**: <code>Fetch Istio Proxy Logs in Cluster `${CONTEXT}`</code>
- **Sub-metric name**: `proxy_logs`
- **Underlying script**: `istio_proxy_logs.sh`
- **Tags**: —
- **Reads**: —
- **Pass condition**: `len(@{issues}) == 0`


#### Verify Istio SSL Certificates in Cluster `${CONTEXT}`

Check Istio valid Root CA and mTLS Certificates in Cluster

- **Robot task name**: <code>Verify Istio SSL Certificates in Cluster `${CONTEXT}`</code>
- **Sub-metric name**: `ssl_certificates`
- **Underlying script**: `istio_mtls_check.sh`
- **Tags**: —
- **Reads**: —
- **Pass condition**: `len(@{issues}) == 0`


#### Check Istio Configuration Health in Cluster `${CONTEXT}`

Check Istio configurations in Cluster

- **Robot task name**: <code>Check Istio Configuration Health in Cluster `${CONTEXT}`</code>
- **Sub-metric name**: `configuration`
- **Underlying script**: `analyze_istio_configurations.sh`
- **Tags**: —
- **Reads**: —
- **Pass condition**: `len(@{issues}) == 0`


## Inputs

| Name | Type | Description | Default | Required |
|---|---|---|---|---|
| `KUBERNETES_DISTRIBUTION_BINARY` | string | Which binary to use for Kubernetes CLI commands. | `kubectl` | no |
| `CONTEXT` | string | Which Kubernetes context to operate within. | — | yes |
| `EXCLUDED_NAMESPACES` | string | Comma-separated list of namespaces to exclude from checks (e.g., kube-system,istio-system). | `kube-system` | no |
| `CPU_USAGE_THRESHOLD` | string | The Threshold for the CPU usage. | `80` | no |
| `MEMORY_USAGE_THRESHOLD` | string | The Threshold for the MEMORY usage. | `80` | no |

## Secrets

_No secrets imported in Robot source._

## Outputs

- Monitor health score (`0.0`–`1.0`) pushed by `sli.robot`
- `issues.json`
- `istio_sidecar_resource_usage_issue.json`
- `istio_installation_issues.json`
- `istio_controlplane_issues.json`
- `istio_controlplane_report.json`
- `istio_proxy_issues.json`
- `istio_proxy_report.json`
- `istio_mtls_issues.json`
- `issues_istio_analyze.json`

## How to invoke

### Production (RunWhen runner / worker)

The platform **runner** schedules work on a location **worker**. The worker
image (`rw-base-runtime`) executes Robot via `runrobot.sh` with
`RW_PATH_TO_ROBOT` set to the bound path under `/home/runwhen/collection/`.

- **Runbook**: `codebundles/k8s-istio-system-health/runbook.robot`
- **Monitor**: `codebundles/k8s-istio-system-health/sli.robot`

### Local development (devcontainer only)

`ro` is a dev-time wrapper in `codecollection-devtools` — not the enterprise runtime.

```bash
cd codebundles/k8s-istio-system-health
export KUBERNETES_DISTRIBUTION_BINARY=...
export CONTEXT=...
export EXCLUDED_NAMESPACES=...
export CPU_USAGE_THRESHOLD=...
export MEMORY_USAGE_THRESHOLD=...
ro runbook.robot
```

### Standalone scripts (no Robot)


Set the input variables above, then run the matching script:

```bash
cd codebundles/k8s-istio-system-health
export KUBERNETES_DISTRIBUTION_BINARY=...
export CONTEXT=...
export EXCLUDED_NAMESPACES=...
export CPU_USAGE_THRESHOLD=...
bash analyze_istio_configurations.sh
bash check_istio_injection.sh
bash istio_controlplane_logs.sh
bash istio_installation_verify.sh
bash istio_mtls_check.sh
bash istio_proxy_logs.sh
bash istio_sidecar_injection_report.sh
bash istio_sidecar_resource_usage.sh
```

## Source files

- `runbook.robot` — orchestrates tools and raises issues
- `sli.robot` — monitor scoring (`sli.robot` runtime file)
- `analyze_istio_configurations.sh` — Bash helper script `analyze_istio_configurations.sh`.
- `check_istio_injection.sh` — Bash helper script `check_istio_injection.sh`.
- `istio_controlplane_logs.sh` — Bash helper script `istio_controlplane_logs.sh`.
- `istio_installation_verify.sh` — Bash helper script `istio_installation_verify.sh`.
- `istio_mtls_check.sh` — Bash helper script `istio_mtls_check.sh`.
- `istio_proxy_logs.sh` — Bash helper script `istio_proxy_logs.sh`.
- `istio_sidecar_injection_report.sh` — Bash helper script `istio_sidecar_injection_report.sh`.
- `istio_sidecar_resource_usage.sh` — Bash helper script `istio_sidecar_resource_usage.sh`.
