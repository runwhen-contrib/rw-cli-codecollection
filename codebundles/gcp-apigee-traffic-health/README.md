# GCP Apigee Traffic and Performance Health

This CodeBundle monitors the runtime traffic, performance, and reliability of
Apigee API proxying via Cloud Monitoring. It flags elevated error/fault rates,
high latency percentiles, throughput anomalies and anomalies detected by Apigee,
and degraded target/backend behavior, so operators are alerted to API slowness,
spikes of 5xx errors, or backend degradation before consumers are impacted.

## Overview

The bundle enumerates the Apigee organization's proxies, environments, and
target servers, then evaluates runtime performance across four dimensions using
Cloud Monitoring metrics:

- **Error and fault rates**: Flags proxies whose 4xx/5xx or fault rate exceeds `ERROR_RATE_THRESHOLD`
- **Latency performance**: Flags proxies whose p95/p99 latency exceeds `LATENCY_MS_THRESHOLD`
- **Throughput and anomalies**: Flags anomalous traffic (spikes or drops) and Apigee-detected anomalies
- **Target and backend performance**: Flags slow or failing backend target servers

All metrics are under the `apigee.googleapis.com/` domain (e.g.
`proxyv2/request_count`, `proxyv2/latencies_percentile`, `server/fault_count`,
`targetv2/request_count`, `environment/anomaly_count`, `environment/api_call_count`)
and are queried via the Cloud Monitoring timeSeries API in `GCP_PROJECT_ID` using
the service-account credentials.

## Configuration

### Required Variables

- `APIGEE_ORG`: The Apigee organization name that scopes which proxies, environments, and target servers are evaluated.
- `GCP_PROJECT_ID`: The GCP project ID that hosts the Apigee runtime and is the Cloud Monitoring scope for metric queries.

### Optional Variables

- `ERROR_RATE_THRESHOLD`: Error/fault rate (percent of requests returning 4xx/5xx or faults) above which a proxy is flagged. (default: `5`)
- `LATENCY_MS_THRESHOLD`: p95 latency in milliseconds above which a proxy is flagged as slow. (default: `500`)
- `METRIC_WINDOW_MIN`: Lookback window in minutes for the Cloud Monitoring metric queries. (default: `60`)

### Secrets

- `gcp_credentials`: A GCP service account JSON key with `roles/monitoring.viewer`
  (or `roles/monitoring.viewer` scoped to the Apigee metrics) and
  `roles/apigee.viewer` on the organization. Format is the standard GCP service
  account JSON object (containing `type`, `project_id`, `private_key_id`,
  `private_key`, `client_email`, `client_id`, `auth_uri`, `token_uri`).

## SLI

The SLI produces a continuous 0-1 health score, averaged across four dimensions
(each pushed as a sub-metric):

- `error_rate` — 1.0 if no proxies exceed `ERROR_RATE_THRESHOLD`, else 0.0
- `latency_performance` — 1.0 if no proxies exceed `LATENCY_MS_THRESHOLD`, else 0.0
- `throughput_anomaly` — 1.0 if no throughput anomalies are detected, else 0.0
- `target_performance` — 1.0 if no target servers are degraded, else 0.0

The aggregate is the arithmetic mean of the four dimension scores.

## Tasks Overview

### Discover Apigee Proxies and Environments for Metrics
Enumerates API proxies, environments, and target servers at org scope to scope the metric checks and map proxy/environment labels for the Cloud Monitoring queries. Reports issues when the Apigee Admin API cannot be reached or the org cannot be enumerated.

### Check Apigee API Error and Fault Rates
Queries proxy-level proxyv2 request/response counts and server fault_count metrics over the window to compute error/fault rates, flagging proxies whose 4xx/5xx or fault rate exceeds `ERROR_RATE_THRESHOLD`.

### Check Apigee API Latency Performance
Queries proxyv2/percentile latency metrics (p50/p90/p99) and flags proxies whose p95/p99 latency exceeds `LATENCY_MS_THRESHOLD`, indicating slow APIs.

### Check Apigee Throughput and Anomalies
Reviews request/response volume and the `environment/anomaly_count` metric, flagging anomalous traffic (spikes or drops) that may indicate an incident, a mis-route, or a dead backend.

### Check Apigee Target and Backend Performance
Queries target/upstream request, response, and latency metrics to detect slow or failing backend target servers, flagging targets with elevated latency or errors.

### Generate Apigee Traffic Health Summary
Aggregates error, latency, throughput, and target findings into a consolidated traffic health summary (worst proxies by error rate and latency, anomaly count, overall verdict) and reports an aggregated issue when overall health is degraded.

## Requirements

The following IAM permissions are required on the service account (via a custom role, or `roles/monitoring.viewer` + `roles/apigee.viewer`):

- `monitoring.timeSeries.list`
- `apigee.proxies.list`
- `apigee.environments.list`
- `apigee.targetservers.list`
- `apigee.organizations.list`

The `gcloud`, `jq`, and `curl` CLI tools are required at runtime. The Cloud
Monitoring and Apigee APIs must be enabled for the project, and the Apigee
runtime must be sending metrics to Cloud Monitoring.
