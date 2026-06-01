---
name: k8s-ingress-gce-healthcheck
kind: skill-template
description: Troubleshoot GCE Ingress Resources related to GCP HTTP Load Balancer in GKE. Use when triaging or monitoring Kubernetes, GKE, GCE workloads with skill template `k8s-ingress-gce-healthcheck`.
runtime:
  runbook: runbook.robot
  runner: ro
platforms: [Kubernetes, GKE, GCE, GCP]
resource_types: [ingress]
access: read-only
---

# Kubernetes Ingress GCE & GCP HTTP Load Balancer Healthcheck

## Summary

Triages the GCP HTTP Load Balancer resources that are created when an ingress object is detected and created by the ingress-gce controller.

See [README.md](README.md) for additional context.

## Tools

### Search For GCE Ingress Warnings in GKE Context `${CONTEXT}`

Find warning events related to GCE Ingress and services objects

- **Robot task name**: <code>Search For GCE Ingress Warnings in GKE Context `${CONTEXT}`</code>
- **Robot file**: `runbook.robot`
- **Tags**: `access:read-only`, `service`, `ingress`, `endpoint`, `health`, `ingress-gce`, `gke`, `data:config`
- **Reads**: `CONTEXT`, `GCP_PROJECT_ID`, `INGRESS`, `KUBERNETES_DISTRIBUTION_BINARY`, `NAMESPACE`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Identify Unhealthy GCE HTTP Ingress Backends in GKE Namespace `${NAMESPACE}`

Checks the backend annotations on the ingress object to determine if they are not regstered as healthy

- **Robot task name**: <code>Identify Unhealthy GCE HTTP Ingress Backends in GKE Namespace `${NAMESPACE}`</code>
- **Robot file**: `runbook.robot`
- **Tags**: `access:read-only`, `service`, `ingress`, `endpoint`, `health`, `ingress-gce`, `gke`, `data:config`
- **Reads**: `CONTEXT`, `INGRESS`, `KUBERNETES_DISTRIBUTION_BINARY`, `NAMESPACE`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Validate GCP HTTP Load Balancer Configurations in GCP Project `${GCP_PROJECT_ID}`

Extract GCP HTTP Load Balancer components from ingress annotations and check health of each object

- **Robot task name**: <code>Validate GCP HTTP Load Balancer Configurations in GCP Project `${GCP_PROJECT_ID}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `check_gce_ingress_objects.sh`
- **Tags**: `access:read-only`, `service`, `ingress`, `endpoint`, `health`, `backends`, `urlmap`, `gce`, `data:config`
- **Reads**: `INGRESS`, `NAMESPACE`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Fetch Network Error Logs from GCP Operations Manager for Ingress Backends in GCP Project `${GCP_PROJECT_ID}`

Fetch logs from the last 1d that are specific to the HTTP Load Balancer within the last 60 minutes

- **Robot task name**: <code>Fetch Network Error Logs from GCP Operations Manager for Ingress Backends in GCP Project `${GCP_PROJECT_ID}`</code>
- **Robot file**: `runbook.robot`
- **Tags**: `access:read-only`, `service`, `ingress`, `endpoint`, `health`, `data:logs-regexp`
- **Reads**: `CONTEXT`, `GCP_PROJECT_ID`, `INGRESS`, `KUBERNETES_DISTRIBUTION_BINARY`, `NAMESPACE`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Review GCP Operations Logging Dashboard in GCP project `${GCP_PROJECT_ID}`

Create urls that will help users obtain logs from the GCP Dashboard

- **Robot task name**: <code>Review GCP Operations Logging Dashboard in GCP project `${GCP_PROJECT_ID}`</code>
- **Robot file**: `runbook.robot`
- **Tags**: `access:read-only`, `service`, `ingress`, `endpoint`, `health`, `logging`, `http`, `loadbalancer`, `data:logs-regexp`
- **Reads**: `CONTEXT`, `INGRESS`, `KUBERNETES_DISTRIBUTION_BINARY`, `NAMESPACE`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


## Inputs

| Name | Type | Description | Default | Required |
|---|---|---|---|---|
| `NAMESPACE` | string | The name of the Kubernetes namespace to scope actions and searching to. | — | yes |
| `CONTEXT` | string | Which Kubernetes context to operate within. | — | yes |
| `INGRESS` | string | Which Ingress object to troubleshoot. | — | yes |
| `KUBERNETES_DISTRIBUTION_BINARY` | string | Which binary to use for Kubernetes CLI commands. | `kubectl` | no |
| `GCP_PROJECT_ID` | string | The GCP Project ID to scope the API to. | — | yes |

## Secrets

| Name | Description | Required |
|---|---|---|
| `gcp_credentials` | GCP service account json used to authenticate with GCP APIs. | yes |

## Outputs

_See Robot run output and platform report artifacts._

## How to invoke

### Preferred: Robot Framework runner (`ro`)

```bash
cd codebundles/k8s-ingress-gce-healthcheck
export NAMESPACE=...
export CONTEXT=...
export INGRESS=...
export KUBERNETES_DISTRIBUTION_BINARY=...
export GCP_PROJECT_ID=...
ro runbook.robot
```

### Standalone scripts (no Robot)


Set the input variables above, then run the matching script:

```bash
cd codebundles/k8s-ingress-gce-healthcheck
export NAMESPACE=...
export CONTEXT=...
export INGRESS=...
export KUBERNETES_DISTRIBUTION_BINARY=...
bash check_gce_ingress_objects.sh
```

## Source files

- `runbook.robot` — orchestrates tools and raises issues
- `check_gce_ingress_objects.sh` — Bash helper script `check_gce_ingress_objects.sh`.
