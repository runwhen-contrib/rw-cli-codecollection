---
name: curl-gmp-kong-ingress-inspection
kind: skill-template
description: Collects Kong ingress host metrics from GMP on GCP and inspects the results for ingress with a HTTP error code rate... Use when triaging or monitoring GCP, GMP, Ingress workloads with skill templat...
runtime:
  runbook: runbook.robot
  runner: ro
platforms: [GCP, GMP, Ingress, Kong, Metrics]
resource_types: [ingress]
access: read-only
---

# GKE Kong Ingress Host Triage

## Summary

This code collects Kong ingress host metrics from Google Monitoring Platform (GMP) on Google Cloud Platform (GCP) and inspects the results for ingresses with a HTTP error code rate greater than zero over a configurable duration.

See [README.md](README.md) for additional context.

## Tools

### Check If Kong Ingress HTTP Error Rate Violates HTTP Error Threshold in GCP Project `${GCP_PROJECT_ID}`

Fetches HTTP Error metrics for the Kong ingress host and service from GMP and performs an inspection on the results. If there are currently any results with more than the defined HTTP error threshold, their route and service names will be surfaced for further troubleshooting.

- **Robot task name**: <code>Check If Kong Ingress HTTP Error Rate Violates HTTP Error Threshold in GCP Project `${GCP_PROJECT_ID}`</code>
- **Robot file**: `runbook.robot`
- **Tags**: `curl`, `http`, `ingress`, `errors`, `metrics`, `kong`, `gmp`, `access:read-only`, `data:config`
- **Reads**: `GCP_PROJECT_ID`, `HTTP_ERROR_RATE_THRESHOLD`, `TIME_SLICE`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Check If Kong Ingress HTTP Request Latency Violates Threshold in GCP Project `${GCP_PROJECT_ID}`

Fetches metrics for the Kong ingress 99th percentile request latency from GMP and performs an inspection on the results. If there are currently any results with more than the defined request latency threshold, their route and service names will be surfaced for further troubleshooting.

- **Robot task name**: <code>Check If Kong Ingress HTTP Request Latency Violates Threshold in GCP Project `${GCP_PROJECT_ID}`</code>
- **Robot file**: `runbook.robot`
- **Tags**: `curl`, `request`, `ingress`, `latency`, `http`, `kong`, `gmp`, `access:read-only`, `data:config`
- **Reads**: `GCP_PROJECT_ID`, `REQUEST_LATENCY_THRESHOLD`, `TIME_SLICE`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Check If Kong Ingress Controller Reports Upstream Errors in GCP Project `${GCP_PROJECT_ID}`

Fetches metrics for the Kong ingress controller related to upstream healthchecks or dns errors.

- **Robot task name**: <code>Check If Kong Ingress Controller Reports Upstream Errors in GCP Project `${GCP_PROJECT_ID}`</code>
- **Robot file**: `runbook.robot`
- **Tags**: `curl`, `request`, `ingress`, `upstream`, `healthcheck`, `dns`, `errrors`, `http`, `kong`, `gmp`, `access:read-only`, `data:config`
- **Reads**: `GCP_PROJECT_ID`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


## Inputs

| Name | Type | Description | Default | Required |
|---|---|---|---|---|
| `GCP_PROJECT_ID` | string | The GCP Project ID to scope the API to. | — | yes |
| `TIME_SLICE` | string | Specify the window of time used to measure the rate. | `1m` | no |
| `HTTP_ERROR_RATE_THRESHOLD` | string | Specify the error rate threshold that is considered unhealthy. Measured in errors/s. | `0.5` | no |
| `REQUEST_LATENCY_THRESHOLD` | string | The threshold in ms for request latency to be considered unhealthy. | — | yes |

## Secrets

| Name | Description | Required |
|---|---|---|
| `gcp_credentials` | GCP service account json used to authenticate with GCP APIs. | yes |

## Outputs

_See Robot run output and platform report artifacts._

## How to invoke

### Preferred: Robot Framework runner (`ro`)

```bash
cd codebundles/curl-gmp-kong-ingress-inspection
export GCP_PROJECT_ID=...
export TIME_SLICE=...
export HTTP_ERROR_RATE_THRESHOLD=...
export REQUEST_LATENCY_THRESHOLD=...
ro runbook.robot
```

### Standalone scripts (no Robot)


_No standalone shell scripts in this bundle._

## Source files

- `runbook.robot` — orchestrates tools and raises issues
