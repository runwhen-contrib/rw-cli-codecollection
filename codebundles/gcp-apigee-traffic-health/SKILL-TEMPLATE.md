---
name: gcp-apigee-traffic-health
kind: skill-template
description: Monitor the runtime traffic, performance, and reliability of GCP Apigee API proxying via Cloud Monitoring (error/fault rates, latency, throughput anomalies, target/backend performance). Use when triaging or monitoring Apigee workloads with skill template `gcp-apigee-traffic-health`.
runtime:
  runbook: runbook.robot
  monitor: sli.robot
  executor: worker
  entrypoint: /home/runwhen/robot-runtime/runrobot.sh
  base_image: rw-base-runtime
platforms: [GCP, Apigee]
resource_types: [gcp_resource]
access: read-only
---

# GCP Apigee Traffic and Performance Health

## Summary

This codebundle monitors the runtime traffic, performance, and reliability of Apigee API proxying via Cloud Monitoring. It flags elevated error/fault rates, high latency percentiles, throughput anomalies, and degraded target/backend behavior.

See [README.md](README.md) for additional context.

## Tools

### Discover Apigee Proxies and Environments for Metrics in `${APIGEE_ORG}`

Enumerates API proxies, environments, and target servers at org scope to scope the metric checks and map proxy/environment labels for the Cloud Monitoring queries.

- **Robot task name**: <code>Discover Apigee Proxies and Environments for Metrics in `${APIGEE_ORG}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `discover_metrics_scope.sh`
- **Tags**: `gcloud`, `apigee`, `gcp`, `${APIGEE_ORG}`, `access:read-only`, `data:config`
- **Reads**: `APIGEE_ORG`, `GCP_PROJECT_ID`
- **Writes**: `apigee_scope.json`, `discovery_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when scope discovery fails

### Check Apigee API Error and Fault Rates in `${GCP_PROJECT_ID}`

Queries proxy-level proxyv2 request/response counts and server fault_count metrics over the window to compute error/fault rates, flagging proxies whose 4xx/5xx or fault rate exceeds `ERROR_RATE_THRESHOLD`.

- **Robot task name**: <code>Check Apigee API Error and Fault Rates in `${GCP_PROJECT_ID}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `check_error_rates.sh`
- **Tags**: `gcloud`, `apigee`, `monitoring`, `gcp`, `${GCP_PROJECT_ID}`, `access:read-only`, `data:metrics`
- **Reads**: `GCP_PROJECT_ID`, `ERROR_RATE_THRESHOLD`, `METRIC_WINDOW_MIN`
- **Writes**: `error_rate_issues.json`, `error_rate_report.json`
- **Issues raised**: severity 3 per proxy exceeding the error/fault rate threshold

### Check Apigee API Latency Performance in `${GCP_PROJECT_ID}`

Queries proxyv2/percentile latency metrics (p50/p90/p99) and flags proxies whose p95/p99 latency exceeds `LATENCY_MS_THRESHOLD`, indicating slow APIs.

- **Robot task name**: <code>Check Apigee API Latency Performance in `${GCP_PROJECT_ID}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `check_latency.sh`
- **Tags**: `gcloud`, `apigee`, `monitoring`, `gcp`, `${GCP_PROJECT_ID}`, `access:read-only`, `data:metrics`
- **Reads**: `GCP_PROJECT_ID`, `LATENCY_MS_THRESHOLD`, `METRIC_WINDOW_MIN`
- **Writes**: `latency_issues.json`, `latency_report.json`
- **Issues raised**: severity 3 per proxy exceeding the latency threshold

### Check Apigee Throughput and Anomalies in `${GCP_PROJECT_ID}`

Reviews request/response volume and the `environment/anomaly_count` metric, flagging anomalous traffic (spikes or drops) that may indicate an incident, a mis-route, or a dead backend.

- **Robot task name**: <code>Check Apigee Throughput and Anomalies in `${GCP_PROJECT_ID}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `check_throughput.sh`
- **Tags**: `gcloud`, `apigee`, `monitoring`, `gcp`, `${GCP_PROJECT_ID}`, `access:read-only`, `data:metrics`
- **Reads**: `GCP_PROJECT_ID`, `METRIC_WINDOW_MIN`
- **Writes**: `throughput_issues.json`, `throughput_report.json`
- **Issues raised**: severity 2 per environment with detected anomalies or throughput deviation

### Check Apigee Target and Backend Performance in `${GCP_PROJECT_ID}`

Queries target/upstream request, response, and latency metrics to detect slow or failing backend target servers, flagging targets with elevated latency or errors.

- **Robot task name**: <code>Check Apigee Target and Backend Performance in `${GCP_PROJECT_ID}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `check_target_performance.sh`
- **Tags**: `gcloud`, `apigee`, `monitoring`, `gcp`, `${GCP_PROJECT_ID}`, `access:read-only`, `data:metrics`
- **Reads**: `GCP_PROJECT_ID`, `ERROR_RATE_THRESHOLD`, `LATENCY_MS_THRESHOLD`, `METRIC_WINDOW_MIN`
- **Writes**: `target_performance_issues.json`, `target_report.json`
- **Issues raised**: severity 3 per degraded target server

### Generate Apigee Traffic Health Summary for `${APIGEE_ORG}`

Aggregates error, latency, throughput, and target findings into a consolidated traffic health summary (worst proxies by error rate and latency, anomaly count, overall verdict).

- **Robot task name**: <code>Generate Apigee Traffic Health Summary for `${APIGEE_ORG}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `generate_traffic_summary.sh`
- **Tags**: `gcloud`, `apigee`, `gcp`, `${APIGEE_ORG}`, `access:read-only`, `data:metrics`
- **Reads**: `APIGEE_ORG`, `GCP_PROJECT_ID`, `ERROR_RATE_THRESHOLD`, `LATENCY_MS_THRESHOLD`
- **Writes**: `traffic_summary_table.txt`, `traffic_summary_issues.json`
- **Issues raised**: severity 2/3 aggregated issue when overall traffic health is degraded

## Monitor

This SLI scores GCP Apigee traffic and performance health by evaluating error/fault rates, latency performance, throughput/anomaly status, and target/backend performance. Produces a value between 0 (completely failing) and 1 (fully healthy).

- **Robot file**: `sli.robot`
- **Score range**: `0.0` (failing) to `1.0` (healthy)
- **Aggregation**: arithmetic mean of the sub-checks below
- **Recommended interval**: `300s`

### Sub-checks

#### Score Apigee Error and Fault Rates in `${GCP_PROJECT_ID}`

Scores 1.0 if no proxies exceed `ERROR_RATE_THRESHOLD`, 0.0 otherwise.

- **Robot task name**: <code>Score Apigee Error and Fault Rates in `${GCP_PROJECT_ID}`</code>
- **Sub-metric names**: `error_rate`, `high_error_rate_count`
- **Underlying script**: `check_error_rates.sh`
- **Tags**: `gcloud`, `apigee`, `monitoring`, `gcp`, `${GCP_PROJECT_ID}`, `data:metrics`, `access:read-only`
- **Reads**: `GCP_PROJECT_ID`, `ERROR_RATE_THRESHOLD`, `METRIC_WINDOW_MIN`
- **Pass condition**: `high_error_rate_count == 0`

#### Score Apigee Latency Performance in `${GCP_PROJECT_ID}`

Scores 1.0 if no proxies exceed `LATENCY_MS_THRESHOLD`, 0.0 otherwise.

- **Robot task name**: <code>Score Apigee Latency Performance in `${GCP_PROJECT_ID}`</code>
- **Sub-metric names**: `latency_performance`, `high_latency_count`
- **Underlying script**: `check_latency.sh`
- **Tags**: `gcloud`, `apigee`, `monitoring`, `gcp`, `${GCP_PROJECT_ID}`, `data:metrics`, `access:read-only`
- **Reads**: `GCP_PROJECT_ID`, `LATENCY_MS_THRESHOLD`, `METRIC_WINDOW_MIN`
- **Pass condition**: `high_latency_count == 0`

#### Score Apigee Throughput and Anomalies in `${GCP_PROJECT_ID}`

Scores 1.0 if no throughput anomalies are detected, 0.0 otherwise.

- **Robot task name**: <code>Score Apigee Throughput and Anomalies in `${GCP_PROJECT_ID}`</code>
- **Sub-metric names**: `throughput_anomaly`, `throughput_anomaly_count`
- **Underlying script**: `check_throughput.sh`
- **Tags**: `gcloud`, `apigee`, `monitoring`, `gcp`, `${GCP_PROJECT_ID}`, `data:metrics`, `access:read-only`
- **Reads**: `GCP_PROJECT_ID`, `METRIC_WINDOW_MIN`
- **Pass condition**: `throughput_anomaly_count == 0`

#### Score Apigee Target and Backend Performance in `${GCP_PROJECT_ID}`

Scores 1.0 if no target servers are degraded, 0.0 otherwise.

- **Robot task name**: <code>Score Apigee Target and Backend Performance in `${GCP_PROJECT_ID}`</code>
- **Sub-metric names**: `target_performance`, `degraded_target_count`
- **Underlying script**: `check_target_performance.sh`
- **Tags**: `gcloud`, `apigee`, `monitoring`, `gcp`, `${GCP_PROJECT_ID}`, `data:metrics`, `access:read-only`
- **Reads**: `GCP_PROJECT_ID`, `ERROR_RATE_THRESHOLD`, `LATENCY_MS_THRESHOLD`, `METRIC_WINDOW_MIN`
- **Pass condition**: `degraded_target_count == 0`

## Inputs

| Name | Type | Description | Default | Required |
|---|---|---|---|---|
| `APIGEE_ORG` | string | The Apigee organization name that scopes which proxies, environments, and target servers are evaluated. | — | yes |
| `GCP_PROJECT_ID` | string | The GCP project ID that hosts the Apigee runtime and is the Cloud Monitoring scope for metric queries. | — | yes |
| `ERROR_RATE_THRESHOLD` | string | Error/fault rate (percent of requests returning 4xx/5xx or faults) above which a proxy is flagged. | `5` | no |
| `LATENCY_MS_THRESHOLD` | string | p95 latency in milliseconds above which a proxy is flagged as slow. | `500` | no |
| `METRIC_WINDOW_MIN` | string | Lookback window in minutes for the Cloud Monitoring metric queries. | `60` | no |

## Secrets

| Name | Description | Required |
|---|---|---|
| `gcp_credentials` | GCP service account json used to authenticate with GCP APIs and Cloud Monitoring. | yes |

## Outputs

- Monitor health score (`0.0`–`1.0`) pushed by `sli.robot`
- Sub-metrics per health dimension with raw issue counts
- `apigee_scope.json`
- `discovery_issues.json`
- `error_rate_issues.json`, `error_rate_report.json`
- `latency_issues.json`, `latency_report.json`
- `throughput_issues.json`, `throughput_report.json`
- `target_performance_issues.json`, `target_report.json`
- `traffic_summary_table.txt`, `traffic_summary_issues.json`

## How to invoke

### Production (RunWhen runner / worker)

The platform **runner** schedules work on a location **worker**. The worker
image (`rw-base-runtime`) executes Robot via `runrobot.sh` with
`RW_PATH_TO_ROBOT` set to the bound path under `/home/runwhen/collection/`.

- **Runbook**: `codebundles/gcp-apigee-traffic-health/runbook.robot`
- **Monitor**: `codebundles/gcp-apigee-traffic-health/sli.robot`

### Local development (devcontainer only)

`ro` is a dev-time wrapper in `codecollection-devtools` — not the enterprise runtime.

```bash
cd codebundles/gcp-apigee-traffic-health
export APIGEE_ORG=my-apigee-org
export GCP_PROJECT_ID=my-project
export ERROR_RATE_THRESHOLD=5
export LATENCY_MS_THRESHOLD=500
export METRIC_WINDOW_MIN=60
ro runbook.robot
```

### Standalone scripts (no Robot)

Set the input variables above, then run the matching script:

```bash
cd codebundles/gcp-apigee-traffic-health
export APIGEE_ORG=my-apigee-org
export GCP_PROJECT_ID=my-project
export ERROR_RATE_THRESHOLD=5
export LATENCY_MS_THRESHOLD=500
export METRIC_WINDOW_MIN=60
bash discover_metrics_scope.sh
bash check_error_rates.sh
bash check_latency.sh
bash check_throughput.sh
bash check_target_performance.sh
bash generate_traffic_summary.sh
```

## Source files

- `runbook.robot` — orchestrates tools and raises issues
- `sli.robot` — monitor scoring across four health dimensions
- `discover_metrics_scope.sh` — enumerates proxies, environments, and target servers
- `check_error_rates.sh` — queries Cloud Monitoring for 4xx/5xx and fault rates
- `check_latency.sh` — queries Cloud Monitoring for p95/p99 latency performance
- `check_throughput.sh` — reviews volume and environment anomaly count
- `check_target_performance.sh` — detects slow or failing target servers
- `generate_traffic_summary.sh` — aggregates findings into a consolidated health summary
