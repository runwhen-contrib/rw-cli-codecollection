---
name: gcp-cloud-loadbalancer-health
kind: skill-template
description: Identify health and performance problems with GCP Cloud Load Balancers (SSL, backends, error rates, and latency). Use when triaging or monitoring GCP, Cloud Load Balancing workloads with skill template `gcp-cloud-loadbalancer-health`.
runtime:
  runbook: runbook.robot
  monitor: sli.robot
  executor: worker
  entrypoint: /home/runwhen/robot-runtime/runrobot.sh
  base_image: rw-base-runtime
platforms: [GCP, Cloud Load Balancing]
resource_types: [gcp_resource]
access: read-only
---

# GCP Cloud Load Balancer Health

## Summary

This codebundle monitors the health and performance of GCP Cloud Load Balancers (external HTTP/S, internal HTTP/S, SSL proxy, TCP proxy, and network load balancers). It checks SSL certificate validity, backend health status, error rates via Cloud Monitoring, and latency performance to ensure load balancers are operating within normal operational parameters.

See [README.md](README.md) for additional context.

## Tools

### Discover GCP Cloud Load Balancers and Configurations in `${GCP_PROJECT_ID}`

Lists all forwarding rules in the project, categorizes each by load balancer type (HTTP/S, SSL proxy, TCP proxy, Network), and dumps configuration including IP address, ports, target proxy, and backend service. Produces a configuration dump used by the other tasks.

- **Robot task name**: <code>Discover GCP Cloud Load Balancers and Configurations in `${GCP_PROJECT_ID}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `discover_loadbalancers.sh`
- **Tags**: `gcloud`, `loadbalancer`, `gcp`, `${GCP_PROJECT_ID}`, `access:read-only`, `data:config`
- **Reads**: `GCP_PROJECT_ID`
- **Writes**: `lb_config.json`, `lb_discovery_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when discovery fails

### Check SSL Certificate Expiry for HTTPS/SSL Load Balancers in `${GCP_PROJECT_ID}`

For all HTTPS and SSL proxy load balancers, inspects the mapped SSL certificates and flags any that expire within the configurable `SSL_WARNING_DAYS` threshold, reporting days remaining per certificate.

- **Robot task name**: <code>Check SSL Certificate Expiry for HTTPS/SSL Load Balancers in `${GCP_PROJECT_ID}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `check_ssl_certificates.sh`
- **Tags**: `gcloud`, `loadbalancer`, `ssl`, `gcp`, `${GCP_PROJECT_ID}`, `access:read-only`, `data:config`
- **Reads**: `GCP_PROJECT_ID`, `SSL_WARNING_DAYS`
- **Writes**: `ssl_certificate_issues.json`
- **Issues raised**: severity 2 (expiring) / severity 3 (expired) per certificate within the warning window

### Check Load Balancer Backend Health in `${GCP_PROJECT_ID}`

For each backend service used by the project's load balancers, checks backend health status and flags unhealthy backends, draining instances, and backends with degraded capacity.

- **Robot task name**: <code>Check Load Balancer Backend Health in `${GCP_PROJECT_ID}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `check_backend_health.sh`
- **Tags**: `gcloud`, `loadbalancer`, `backend`, `gcp`, `${GCP_PROJECT_ID}`, `access:read-only`, `data:state`
- **Reads**: `GCP_PROJECT_ID`
- **Writes**: `backend_health_issues.json`, `backend_health_report.json`
- **Issues raised**: severity 2 (draining) / severity 3 (unhealthy) per backend

### Analyze Load Balancer Error Rates via Cloud Monitoring in `${GCP_PROJECT_ID}`

Queries Cloud Monitoring metrics for HTTP/S load balancer 5xx error ratios and non-HTTP LB error/health-check failure rates over the lookback period, flagging load balancers whose error rate exceeds `ERROR_RATE_THRESHOLD`.

- **Robot task name**: <code>Analyze Load Balancer Error Rates via Cloud Monitoring in `${GCP_PROJECT_ID}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `check_error_rates.sh`
- **Tags**: `gcloud`, `loadbalancer`, `monitoring`, `gcp`, `${GCP_PROJECT_ID}`, `access:read-only`, `data:metrics`
- **Reads**: `GCP_PROJECT_ID`, `ERROR_RATE_THRESHOLD`, `METRIC_LOOKBACK_PERIOD`
- **Writes**: `error_rate_issues.json`
- **Issues raised**: severity 3 per load balancer exceeding the error rate threshold

### Analyze Load Balancer Latency Performance in `${GCP_PROJECT_ID}`

Queries Cloud Monitoring metrics for request latency (P95) on HTTP/S load balancers and flags load balancers whose latency exceeds `LATENCY_THRESHOLD_MS`.

- **Robot task name**: <code>Analyze Load Balancer Latency Performance in `${GCP_PROJECT_ID}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `check_latency.sh`
- **Tags**: `gcloud`, `loadbalancer`, `monitoring`, `gcp`, `${GCP_PROJECT_ID}`, `access:read-only`, `data:metrics`
- **Reads**: `GCP_PROJECT_ID`, `LATENCY_THRESHOLD_MS`, `METRIC_LOOKBACK_PERIOD`
- **Writes**: `latency_issues.json`
- **Issues raised**: severity 2 per load balancer exceeding the latency threshold

### Generate Load Balancer Health Summary for `${GCP_PROJECT_ID}`

Aggregates findings from all previous checks into a consolidated health summary table showing each load balancer, its type, SSL status, backend status, error rate, latency, and an overall health verdict.

- **Robot task name**: <code>Generate Load Balancer Health Summary for `${GCP_PROJECT_ID}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `generate_lb_summary.sh`
- **Tags**: `gcloud`, `loadbalancer`, `gcp`, `${GCP_PROJECT_ID}`, `access:read-only`, `data:state`
- **Reads**: `GCP_PROJECT_ID`
- **Writes**: `lb_summary_issues.json`, `lb_summary_table.txt`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when summary checks fail

## Monitor

This SLI scores GCP Cloud Load Balancer health by evaluating SSL certificate expiry, backend health, error rates, and latency performance. Produces a value between 0 (completely failing) and 1 (fully healthy).

- **Robot file**: `sli.robot`
- **Score range**: `0.0` (failing) to `1.0` (healthy)
- **Aggregation**: arithmetic mean of the sub-checks below
- **Recommended interval**: `300s`

### Sub-checks

#### Score SSL Certificate Health for Load Balancers in `${GCP_PROJECT_ID}`

Scores 1.0 if no SSL certificates expire within `SSL_WARNING_DAYS`, 0.0 otherwise.

- **Robot task name**: <code>Score SSL Certificate Health for Load Balancers in `${GCP_PROJECT_ID}`</code>
- **Sub-metric names**: `ssl_certificate_health`, `expiring_cert_count`
- **Underlying script**: `check_ssl_certificates.sh`
- **Tags**: `gcloud`, `loadbalancer`, `ssl`, `gcp`, `${GCP_PROJECT_ID}`, `data:config`, `access:read-only`
- **Reads**: `GCP_PROJECT_ID`, `SSL_WARNING_DAYS`
- **Pass condition**: `expiring_cert_count == 0`

#### Score Backend Health for Load Balancers in `${GCP_PROJECT_ID}`

Scores the ratio of healthy backends to total backends across all load balancers (1.0 if none unhealthy).

- **Robot task name**: <code>Score Backend Health for Load Balancers in `${GCP_PROJECT_ID}`</code>
- **Sub-metric names**: `backend_health`, `unhealthy_backend_count`
- **Underlying script**: `check_backend_health.sh`
- **Tags**: `gcloud`, `loadbalancer`, `backend`, `gcp`, `${GCP_PROJECT_ID}`, `data:state`, `access:read-only`
- **Reads**: `GCP_PROJECT_ID`
- **Pass condition**: `unhealthy_backend_count == 0`

#### Score Load Balancer Error Rates in `${GCP_PROJECT_ID}`

Scores 1.0 if all load balancers are below `ERROR_RATE_THRESHOLD`, 0.0 otherwise.

- **Robot task name**: <code>Score Load Balancer Error Rates in `${GCP_PROJECT_ID}`</code>
- **Sub-metric names**: `error_rate`, `high_error_rate_count`
- **Underlying script**: `check_error_rates.sh`
- **Tags**: `gcloud`, `loadbalancer`, `monitoring`, `gcp`, `${GCP_PROJECT_ID}`, `data:metrics`, `access:read-only`
- **Reads**: `GCP_PROJECT_ID`, `ERROR_RATE_THRESHOLD`, `METRIC_LOOKBACK_PERIOD`
- **Pass condition**: `high_error_rate_count == 0`

#### Score Load Balancer Latency Performance in `${GCP_PROJECT_ID}`

Scores 1.0 if all load balancers are below `LATENCY_THRESHOLD_MS`, 0.0 otherwise.

- **Robot task name**: <code>Score Load Balancer Latency Performance in `${GCP_PROJECT_ID}`</code>
- **Sub-metric names**: `latency_performance`, `high_latency_count`
- **Underlying script**: `check_latency.sh`
- **Tags**: `gcloud`, `loadbalancer`, `monitoring`, `gcp`, `${GCP_PROJECT_ID}`, `data:metrics`, `access:read-only`
- **Reads**: `GCP_PROJECT_ID`, `LATENCY_THRESHOLD_MS`, `METRIC_LOOKBACK_PERIOD`
- **Pass condition**: `high_latency_count == 0`

## Inputs

| Name | Type | Description | Default | Required |
|---|---|---|---|---|
| `GCP_PROJECT_ID` | string | The GCP Project ID that hosts the load balancers to check. | — | yes |
| `SSL_WARNING_DAYS` | string | Number of days before SSL certificate expiry to raise a warning (severity 2). | `30` | no |
| `ERROR_RATE_THRESHOLD` | string | Maximum acceptable 5xx error ratio (0.01 = 1%) before a load balancer is flagged. | `0.01` | no |
| `LATENCY_THRESHOLD_MS` | string | Maximum acceptable P95 latency in milliseconds before a load balancer is flagged. | `5000` | no |
| `METRIC_LOOKBACK_PERIOD` | string | Cloud Monitoring lookback period for metric queries (seconds, e.g. 3600s). | `3600s` | no |

## Secrets

| Name | Description | Required |
|---|---|---|
| `gcp_credentials` | GCP service account json used to authenticate with GCP APIs. | yes |

## Outputs

- Monitor health score (`0.0`–`1.0`) pushed by `sli.robot`
- Sub-metrics per health dimension with raw issue counts
- `lb_config.json`
- `lb_discovery_issues.json`
- `ssl_certificate_issues.json`
- `backend_health_issues.json`
- `backend_health_report.json`
- `error_rate_issues.json`
- `latency_issues.json`
- `lb_summary_issues.json`
- `lb_summary_table.txt`

## How to invoke

### Production (RunWhen runner / worker)

The platform **runner** schedules work on a location **worker**. The worker
image (`rw-base-runtime`) executes Robot via `runrobot.sh` with
`RW_PATH_TO_ROBOT` set to the bound path under `/home/runwhen/collection/`.

- **Runbook**: `codebundles/gcp-cloud-loadbalancer-health/runbook.robot`
- **Monitor**: `codebundles/gcp-cloud-loadbalancer-health/sli.robot`

### Local development (devcontainer only)

`ro` is a dev-time wrapper in `codecollection-devtools` — not the enterprise runtime.

```bash
cd codebundles/gcp-cloud-loadbalancer-health
export GCP_PROJECT_ID=...
export SSL_WARNING_DAYS=30
export ERROR_RATE_THRESHOLD=0.01
export LATENCY_THRESHOLD_MS=5000
export METRIC_LOOKBACK_PERIOD=3600s
ro runbook.robot
```

### Standalone scripts (no Robot)

Set the input variables above, then run the matching script:

```bash
cd codebundles/gcp-cloud-loadbalancer-health
export GCP_PROJECT_ID=...
export SSL_WARNING_DAYS=30
export ERROR_RATE_THRESHOLD=0.01
export LATENCY_THRESHOLD_MS=5000
export METRIC_LOOKBACK_PERIOD=3600s
bash discover_loadbalancers.sh
bash check_ssl_certificates.sh
bash check_backend_health.sh
bash check_error_rates.sh
bash check_latency.sh
bash generate_lb_summary.sh
```

## Source files

- `runbook.robot` — orchestrates tools and raises issues
- `sli.robot` — monitor scoring across four health dimensions
- `discover_loadbalancers.sh` — lists forwarding rules and classifies load balancers by type
- `check_ssl_certificates.sh` — checks SSL certificate expiry for HTTPS/SSL proxy load balancers
- `check_backend_health.sh` — checks backend service health and flags unhealthy/draining backends
- `check_error_rates.sh` — queries Cloud Monitoring for 5xx error ratios
- `check_latency.sh` — queries Cloud Monitoring for P95 latency performance
- `generate_lb_summary.sh` — aggregates findings into a consolidated health summary table
