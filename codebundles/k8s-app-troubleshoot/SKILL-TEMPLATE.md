---
name: k8s-app-troubleshoot
kind: skill-template
description: Performs application-level troubleshooting by inspecting the logs of a workload for parsable exceptions,. Use when triaging or monitoring Kubernetes, AKS, EKS workloads with skill template `k8s-app...
runtime:
  runbook: runbook.robot
  monitor: sli.robot
  runner: ro
platforms: [Kubernetes, AKS, EKS, GKE, OpenShift]
resource_types: [kubernetes_resource]
access: read-only
---

# Kubernetes Application Troubleshoot

## Summary

This codebundle attempts to identify issues created in application code changes recently.

See [README.md](README.md) for additional context.

## Tools

### Get `${CONTAINER_NAME}` Application Logs from Workload `${WORKLOAD_NAME}` in Namespace `${NAMESPACE}`

Collects the last approximately 300 lines of logs from the workload

- **Robot task name**: <code>Get `${CONTAINER_NAME}` Application Logs from Workload `${WORKLOAD_NAME}` in Namespace `${NAMESPACE}`</code>
- **Robot file**: `runbook.robot`
- **Tags**: `resource`, `application`, `workload`, `logs`, `state`, `${container_name}`, `${workload_name}`, `access:read-only`, `data:logs-bulk`
- **Reads**: `CONTEXT`, `KUBERNETES_DISTRIBUTION_BINARY`, `LABELS`, `NAMESPACE`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Scan `${CONTAINER_NAME}` Application For Misconfigured Environment

Compares codebase to configured infra environment variables and attempts to report missing environment variables in the app

- **Robot task name**: <code>Scan `${CONTAINER_NAME}` Application For Misconfigured Environment</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `env_check.sh`
- **Tags**: `environment`, `variables`, `env`, `infra`, `${container_name}`, `${workload_name}`, `data:config`
- **Reads**: —
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Tail `${CONTAINER_NAME}` Application Logs For Stacktraces in Workload `${WORKLOAD_NAME}`

Performs an inspection on container logs for exceptions/stacktraces, parsing them and attempts to find relevant source code information

- **Robot task name**: <code>Tail `${CONTAINER_NAME}` Application Logs For Stacktraces in Workload `${WORKLOAD_NAME}`</code>
- **Robot file**: `runbook.robot`
- **Tags**: —
- **Reads**: `CONTEXT`, `CREATE_ISSUES`, `KUBERNETES_DISTRIBUTION_BINARY`, `LABELS`, `NAMESPACE`, `REPO_URI`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


## Monitor

Measures the number of exception stacktraces present in an application's logs over a time period.

- **Robot file**: `sli.robot`
- **Score range**: `0.0` (failing) to `1.0` (healthy)
- **Aggregation**: arithmetic mean of the sub-checks below
- **Recommended interval**: `180s`

### Sub-checks

#### Measure Application Exceptions in `${NAMESPACE}`

Examines recent logs for exceptions, providing a count of them.

- **Robot task name**: <code>Measure Application Exceptions in `${NAMESPACE}`</code>
- **Sub-metric name**: `app_troubleshoot`
- **Tags**: `resource`, `application`, `workload`, `logs`, `state`, `exceptions`, `errors`, `data:logs-stacktrace`
- **Reads**: `CONTEXT`, `KUBERNETES_DISTRIBUTION_BINARY`, `LABELS`, `NAMESPACE`


## Inputs

| Name | Type | Description | Default | Required |
|---|---|---|---|---|
| `NAMESPACE` | string | The name of the Kubernetes namespace to scope actions and searching to. | `sock-shop` | no |
| `CONTEXT` | string | Which Kubernetes context to operate within. | `sandbox-cluster-1` | no |
| `KUBERNETES_DISTRIBUTION_BINARY` | string | Which binary to use for Kubernetes CLI commands. | `kubectl` | no |
| `REPO_URI` | string | Repo URI for the source code to inspect. | `https://github.com/runwhen-contrib/runwhen-local` | no |
| `LABELS` | string | The Kubernetes labels used to select the resource for logs. | — | yes |
| `CREATE_ISSUES` | string | Whether or not the taskset should create github issues when it finds problems. | `YES` | no |

## Secrets

_No secrets imported in Robot source._

## Outputs

- Monitor health score (`0.0`–`1.0`) pushed by `sli.robot`

## How to invoke

### Preferred: Robot Framework runner (`ro`)

```bash
cd codebundles/k8s-app-troubleshoot
export NAMESPACE=...
export CONTEXT=...
export KUBERNETES_DISTRIBUTION_BINARY=...
export REPO_URI=...
export LABELS=...
export CREATE_ISSUES=...
ro runbook.robot
```

### Standalone scripts (no Robot)


Set the input variables above, then run the matching script:

```bash
cd codebundles/k8s-app-troubleshoot
export NAMESPACE=...
export CONTEXT=...
export KUBERNETES_DISTRIBUTION_BINARY=...
export REPO_URI=...
bash env_check.sh
```

## Source files

- `runbook.robot` — orchestrates tools and raises issues
- `sli.robot` — monitor scoring (`sli.robot` runtime file)
- `env_check.sh` — Bash helper script `env_check.sh`.
