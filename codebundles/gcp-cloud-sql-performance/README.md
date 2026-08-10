# GCP Cloud SQL Performance

This CodeBundle monitors the performance of GCP Cloud SQL instances in a project. It reviews CPU/memory/disk utilization, throughput and IOPS performance, long-running queries, and storage growth via Cloud Monitoring metrics and instance logs, flagging instances that are over-utilized, perform poorly, or host long-running queries so operators can right-size instances and detect performance degradation before it becomes an availability incident.

## Overview

The bundle discovers all Cloud SQL instances in the target GCP project and analyzes each across four dimensions:

- **Utilization**: Flags instances whose CPU utilization stays above `CPU_THRESHOLD_PERCENT` over the `UTILIZATION_HOURS` look-back window (memory and disk utilization are also reported)
- **Performance**: Flags instances showing throughput spikes or noisy traffic patterns via Cloud Monitoring network and disk IOPS metrics
- **Long-running queries**: Queries Cloud SQL instance logs for queries exceeding `LONG_QUERY_SECONDS` and reports the offending SQL (degrades gracefully with a note when query logging is disabled)
- **Storage growth**: Flags instances at risk of running out of disk, especially high-fill instances without automatic storage increase

## Configuration

### Required Variables

- `GCP_PROJECT_ID`: The GCP project ID that hosts the Cloud SQL instances to check.

### Optional Variables

- `RESOURCES`: Comma-separated list of Cloud SQL instance names to scope to. Defaults to `All` and auto-discovers every instance in the project. (default: `All`)
- `CPU_THRESHOLD_PERCENT`: CPU utilization percentage above which an instance is flagged as over-utilized. (default: `80`)
- `UTILIZATION_HOURS`: Look-back window (hours) for utilization and performance metrics. (default: `6`)
- `LONG_QUERY_SECONDS`: Query duration (seconds) above which a query is considered long-running. (default: `300`)
- `STORAGE_FILL_THRESHOLD_PERCENT`: Storage fill percentage above which an instance without automatic storage increase is flagged. (default: `80`)

### Secrets

- `gcp_credentials`: A GCP service account JSON key with `roles/cloudsql.viewer`, `roles/monitoring.viewer`, and `roles/logging.viewer`. Format is the standard GCP service account JSON object (containing `type`, `project_id`, `private_key_id`, `private_key`, `client_email`, `client_id`, `auth_uri`, `token_uri`).

## SLI

The SLI produces a continuous 0-1 health score, averaged across four dimensions (each pushed as a sub-metric):

- `utilization` — 1.0 if no instances exceed the CPU threshold, else 0.0
- `performance` — 1.0 if no instances show throughput spikes, else 0.0
- `long_running_queries` — 1.0 if no queries exceed `LONG_QUERY_SECONDS`, else 0.0
- `storage` — 1.0 if no instances are at risk of running out of disk, else 0.0

The aggregate is the arithmetic mean of the four dimension scores.

## Tasks Overview

### Review Cloud SQL Instance Utilization
Evaluates CPU, memory, and disk utilization for each Cloud SQL instance via Cloud Monitoring metrics over the look-back window, flagging instances consistently above `CPU_THRESHOLD_PERCENT`.

### Identify Cloud SQL Performance Issues
Analyzes throughput and IOPS metrics from Cloud Monitoring to flag instances with sustained high traffic, throughput spikes, or noisy traffic patterns.

### Identify Long Running Queries
Queries Cloud SQL instance logs for queries whose duration exceeds `LONG_QUERY_SECONDS` and reports the offending SQL. When query/performance logging is disabled, the task degrades gracefully with a note rather than failing.

### Check Cloud SQL Instance Storage Growth
Compares used storage (from Cloud Monitoring) to configured capacity and flags high-fill instances, especially those without automatic storage increase enabled.

## Requirements

The following IAM permissions are required on the service account (via custom roles, or `roles/cloudsql.viewer` + `roles/monitoring.viewer` + `roles/logging.viewer`):

- `cloudsql.instances.list` (and `cloudsql.instances.get` for full settings)
- `monitoring.metricDescriptors.list`
- `monitoring.timeSeries.list`
- `logging.entries.list`

The `gcloud`, `jq`, and `curl` CLI tools are required at runtime. The Cloud SQL Admin, Cloud Monitoring, and Cloud Logging APIs must be enabled for the project. Long-running query detection requires query/performance logging to be enabled on the Cloud SQL instances.
