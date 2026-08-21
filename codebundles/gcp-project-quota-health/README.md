# GCP Project Quota Health

Monitors GCP project-level service quotas across all enabled services, flagging allocation quotas whose usage approaches or exceeds their limits, rate quota consumption and throttling events, quotas above a configurable warning threshold, and quota rejection events surfaced in Cloud Logging. Alerts operators before quota exhaustion impacts workloads.

## Overview

- **Allocation Quota Usage vs Limit**: Enumerates consumer allocation quota metrics for each enabled service via the Service Usage API and computes usage percentage against the configured quota limit. Raises error/critical issues for allocation quotas at or near consumption of their limit.
- **Rate Quota Consumption and Throttling**: Pulls Cloud Monitoring serviceruntime rate quota time-series (quota/rate/net_ingress, net_egress, per-method) over a lookback window and evaluates consumption against limits. Detects throttling events where requests were blocked due to rate limits.
- **Quotas Above Warning Threshold**: Cross-references all discovered quota metrics (allocation and rate) against the configured `QUOTA_WARNING_THRESHOLD` and raises an issue for every quota whose current usage equals or exceeds that threshold.
- **Quota Rejection Events**: Queries Cloud Logging for quota rejection events (HTTP 429 RESOURCE_EXHAUSTED / 403 quota exceeded) across services and aggregates them by service and quota metric, raising issues when rejection volume exceeds a threshold.

## Configuration

### Required Variables

- `GCP_PROJECT_ID`: GCP project ID whose quotas are monitored.

### Optional Variables

- `QUOTA_WARNING_THRESHOLD`: Usage percentage of a quota limit that triggers an issue (0-100) (default: `80`).
- `LOOKBACK_MINUTES`: Lookback window (minutes) for rate quota metrics and Cloud Logging rejection events (default: `1440`).
- `SERVICES`: Comma-separated service names to limit quota checks to; `All` checks every enabled service (default: `All`).
- `REJECTION_THRESHOLD`: Minimum number of quota rejection events in the lookback window that triggers an issue (default: `1`).

### Secrets

- `gcp_credentials`: GCP service account JSON key for authentication. Format: JSON object containing `type`, `project_id`, `private_key_id`, `private_key`, `client_email`, `client_id`, `auth_uri`, `token_uri`.

## Tasks Overview

### Check Allocation Quota Usage vs Limit
Enumerates consumer allocation quota metrics for each enabled service via the Service Usage API and computes usage percentage against the configured quota limit. Raises error/critical issues for allocation quotas at or near consumption of their limit.

### Check Rate Quota Consumption and Throttling Events
Pulls Cloud Monitoring serviceruntime rate quota time-series (quota/rate/net_ingress, net_egress, per-method) over a lookback window and evaluates consumption against limits. Raises error/critical issues when consumption approaches the limit, and critical issues when throttling events (requests blocked due to rate limits) are detected.

### Identify Quotas Above Threshold
Cross-references all discovered quota metrics (allocation and rate) against the configured `QUOTA_WARNING_THRESHOLD` and raises an error issue for every quota whose usage equals or exceeds that threshold, providing service, quota dimension, usage, limit, and percentage.

### Analyze Quota Rejection Events from Cloud Logging
Queries Cloud Logging over the lookback window for quota rejection events (HTTP 429 RESOURCE_EXHAUSTED / 403 quota exceeded) and aggregates them by service and quota metric. Raises warning/error/critical issues when rejection volume exceeds `REJECTION_THRESHOLD`.

## Service Level Indicator (SLI)

The bundle includes an in-repo `sli.robot` that produces a 0-1 health score by averaging four binary dimensions (allocation quota, rate quota, quota threshold, and rejection events). A score of 1 is fully healthy; a score below 1 indicates quota pressure. The score is pushed as the primary metric for alerting, with per-dimension sub-metrics for dashboard drill-down.

## Requirements

The following GCP IAM roles are required on the service account (on the target project):
- `roles/serviceusage.serviceUsageConsumer` — to list enabled services and read consumer quota metrics (`serviceusage.services.get`, `consumerQuotaMetrics.list`).
- `roles/monitoring.viewer` — to read Cloud Monitoring time-series for rate quota consumption.
- `roles/logging.viewer` — to read Cloud Logging quota rejection events.
- `roles/servicequotas.viewer` (optional) — to use the Cloud Quotas API for authoritative quota limits when enabled.
- `roles/serviceusage.quotaViewer` (optional) — to read quota information from the Service Usage API.

### Required APIs

- Service Usage API (`serviceusage.googleapis.com`) — always needed.
- Cloud Monitoring API (`monitoring.googleapis.com`) — for rate quota metrics.
- Cloud Logging API (`logging.googleapis.com`) — for rejection events.

### Cross-Project Authentication

When the service account belongs to a different project than the target `GCP_PROJECT_ID`, gcloud derives the API consumer/quota project from the credential's project. This bundle sets `CLOUDSDK_BILLING_QUOTA_PROJECT=$GCP_PROJECT_ID` and `CLOUDSDK_CORE_PROJECT=$GCP_PROJECT_ID` in the suite environment to pin the quota project to the target project. In-project service accounts are unaffected.

## Platform Tools

- `gcloud` - Google Cloud CLI
- `curl` - REST API client
- `jq` - JSON processor
- `python3` - Python runtime for numeric comparisons
