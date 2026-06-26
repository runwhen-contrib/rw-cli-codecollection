---
name: curl-gmp-nginx-ingress-inspection
kind: skill-template
description: Collects Nginx ingress host controller metrics from GMP on GCP and inspects the results for ingress with a HTTP... Use when triaging or monitoring GCP, GMP, Ingress workloads with skill template `c...
runtime:
  runbook: runbook.robot
  executor: worker
  entrypoint: /home/runwhen/robot-runtime/runrobot.sh
  base_image: rw-base-runtime
platforms: [GCP, GMP, Ingress, Nginx, Metrics]
resource_types: [ingress]
access: read-only
---

# GKE Nginx Ingress Host Triage

## Summary

Runs a task which performs inspects the HTTP error code metrics related to your nginx ingress controller in your GKE kubernetes cluster and raises issues based on the number of ingress with errors.

See [README.md](README.md) for additional context.

## Tools

### Fetch Nginx HTTP Errors From GMP for Ingress `${INGRESS_OBJECT_NAME}`

Fetches metrics for the Nginx ingress host from GMP and performs an inspection on the results.

- **Robot task name**: <code>Fetch Nginx HTTP Errors From GMP for Ingress `${INGRESS_OBJECT_NAME}`</code>
- **Robot file**: `runbook.robot`
- **Tags**: `curl`, `http`, `ingress`, `latency`, `errors`, `metrics`, `controller`, `nginx`, `gmp`, `500s`, `data:config`
- **Reads**: `CONTEXT`, `ERROR_CODES`, `GCP_PROJECT_ID`, `KUBERNETES_DISTRIBUTION_BINARY`, `NAMESPACE`, `TIME_SLICE`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Find Owner and Service Health for Ingress `${INGRESS_OBJECT_NAME}`

Checks the ingress object service and endpoints. Also returns the owner of the pods that support the Ingress.

- **Robot task name**: <code>Find Owner and Service Health for Ingress `${INGRESS_OBJECT_NAME}`</code>
- **Robot file**: `runbook.robot`
- **Tags**: `owner`, `ingress`, `service`, `endpoints`, `data:config`
- **Reads**: `CONTEXT`, `KUBERNETES_DISTRIBUTION_BINARY`, `NAMESPACE`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


## Inputs

| Name | Type | Description | Default | Required |
|---|---|---|---|---|
| `KUBERNETES_DISTRIBUTION_BINARY` | string | Which binary to use for Kubernetes CLI commands. | `kubectl` | no |
| `CONTEXT` | string | Which Kubernetes context to operate within. | — | yes |
| `NAMESPACE` | string | The name of the namespace to search. | `` | yes |
| `GCP_PROJECT_ID` | string | The GCP Project ID to scope the API to. | — | yes |
| `TIME_SLICE` | string | The amount of time to perform aggregations over. | `60m` | no |
| `ERROR_CODES` | string | Which http status codes to look for and classify as errors. | `500|501|502|503|504` | no |

## Secrets

| Name | Description | Required |
|---|---|---|
| `gcp_credentials` | GCP service account json used to authenticate with GCP APIs. | yes |

## Outputs

_See Robot run output and platform report artifacts._

## How to invoke

### Production (RunWhen runner / worker)

The platform **runner** schedules work on a location **worker**. The worker
image (`rw-base-runtime`) executes Robot via `runrobot.sh` with
`RW_PATH_TO_ROBOT` set to the bound path under `/home/runwhen/collection/`.

- **Runbook**: `codebundles/curl-gmp-nginx-ingress-inspection/runbook.robot`

### Local development (devcontainer only)

`ro` is a dev-time wrapper in `codecollection-devtools` — not the enterprise runtime.

```bash
cd codebundles/curl-gmp-nginx-ingress-inspection
export KUBERNETES_DISTRIBUTION_BINARY=...
export CONTEXT=...
export NAMESPACE=...
export GCP_PROJECT_ID=...
export TIME_SLICE=...
ro runbook.robot
```

### Standalone scripts (no Robot)


_No standalone shell scripts in this bundle._

## Source files

- `runbook.robot` — orchestrates tools and raises issues
