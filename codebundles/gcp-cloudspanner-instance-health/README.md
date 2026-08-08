# GCP Cloud Spanner Instance Health

Monitors the operational health of GCP Cloud Spanner instances and their databases — instance/database state, high-priority CPU utilization, storage utilization against per-node/processing-unit limits, and request latency/errors. Helps operators catch under-provisioned or overloaded Spanner instances before they breach Google's recommended CPU/storage thresholds and degrade latency.

## Overview

- **Instance State & Configuration**: Verifies each instance is READY; reports node_count/processing_units and config (regional vs multi-region); flags multi-region instances under-provisioned for their config.
- **High-Priority CPU Utilization**: Reads `spanner.googleapis.com/instance/cpu/utilization_by_priority` (filtered to `priority=high`, not total CPU) from Cloud Monitoring and flags instances above a config-derived ceiling (65% regional, 45% multi-region by default).
- **Storage Utilization**: Derives each instance's storage limit from its node_count/processing_units (~4 TB per node; never hardcoded) and flags instances approaching that limit, which can block writes.
- **Database State**: Lists databases per instance, verifies each is READY, and flags databases stuck in CREATING or long-running schema/DDL operations.
- **Request Latency & Errors**: Pulls request latency and error/abort rates from Cloud Monitoring and flags instances exceeding the configured thresholds.

## Configuration

### Required Variables

- `GCP_PROJECT_ID`: GCP Project ID containing the Cloud Spanner instances.

### Optional Variables

- `CPU_UTILIZATION_THRESHOLD`: High-priority CPU % (regional instances) above which an issue is raised (default: `65`).
- `MULTI_REGION_CPU_UTILIZATION_THRESHOLD`: High-priority CPU % (multi-region instances) above which an issue is raised (default: `45`). Multi-region instances are detected from the instance's config name (configs not prefixed `regional-` are treated as multi-region).
- `STORAGE_UTILIZATION_THRESHOLD`: Storage % of the node/processing-unit-derived limit above which an issue is raised (default: `75`).
- `STORAGE_LIMIT_GB_PER_NODE`: Spanner storage limit in GB per node (or per 1000 processing units), used to derive each instance's storage limit rather than hardcoding it (default: `4096`, ~4 TB/node).
- `LATENCY_THRESHOLD_MS`: Request latency (ms) above which an issue is raised (default: `100`).
- `ERROR_RATE_THRESHOLD_PERCENT`: Request error/abort rate (%) above which an issue is raised (default: `1`).
- `LONG_RUNNING_OPERATION_MINUTES`: Age in minutes above which an incomplete schema/DDL operation is flagged (default: `60`).

### Secrets

- `gcp_credentials`: GCP service account JSON key for authentication. Format: JSON object containing `type`, `project_id`, `private_key_id`, `private_key`, `client_email`, `client_id`, `auth_uri`, `token_uri`. Requires `roles/spanner.viewer` and `roles/monitoring.viewer`.

## Tasks Overview

### Check Cloud Spanner Instance State and Configuration
Verifies each instance is in READY state; reports node_count/processing_units, instance config (regional vs multi-region), and flags multi-region instances provisioned with fewer than 3 nodes.

### Check Cloud Spanner High-Priority CPU Utilization
Reads high-priority CPU utilization (the metric Google alerts on, not total CPU) and flags instances above the config-derived threshold.

### Check Cloud Spanner Storage Utilization
Compares storage used against the instance's storage limit, derived from its node/processing-unit count, and flags instances approaching the limit.

### Check Cloud Spanner Database State
Lists databases per instance, verifies each is READY, and flags databases stuck in CREATING or long-running schema/DDL operations.

### Analyze Cloud Spanner Request Latency and Errors
Pulls read/write request latency and error/abort rates from Cloud Monitoring and flags instances exceeding latency or error-rate thresholds.

## SLI

`sli.robot` produces a 0-1 health score aggregating four dimensions: instance state, high-priority CPU utilization, storage utilization, and database state (each a binary pass/fail, averaged). Request latency/errors is runbook-only (deep investigation), not part of the SLI, to keep the SLI lightweight.

## Requirements

The following GCP IAM roles are required on the service account:
- `roles/spanner.viewer`
- `roles/monitoring.viewer`

## Platform Tools

- `gcloud spanner` - Google Cloud CLI Spanner commands
- `curl` - Cloud Monitoring REST API time-series queries (`gcloud monitoring time-series` does not exist; `monitoring_query.sh` queries the Monitoring v3 API directly with a gcloud access token)
- `jq` - JSON processor
- `python3` - Python runtime (numeric comparisons/formatting)

## Notes / Assumptions

- **Resource type**: The `gcp_spanner_instances` identifier in `.runwhen/generation-rules/` is used **only by RunWhen Local** for auto-discovery/SLX generation (it is the CloudQuery table name RunWhen Local matches against when indexing a project). The runbook and SLI scripts themselves do **not** use it — they discover instances directly via `gcloud spanner instances list --project=$GCP_PROJECT_ID`, so the CodeBundle runs standalone against any GCP project with no RunWhen Local dependency. The name follows the collection's established convention (`gcp_bigquery_datasets`, `gcp_storage_buckets`, `gcp_cloud_run_service`) and CloudQuery's GCP-plugin table name for Spanner. If a given RunWhen Local deployment's CloudQuery config exposes Spanner under a different table name, update `.runwhen/generation-rules/gcp-cloudspanner-instance-health.yaml` accordingly.
- **High-priority CPU**: `check_cpu_utilization.sh` filters `spanner.googleapis.com/instance/cpu/utilization_by_priority` to `metric.labels.priority="high"`, matching Google's own alerting guidance, rather than using total/aggregate CPU.
- **Storage limit derivation**: Storage limits are computed as `node_equivalent * STORAGE_LIMIT_GB_PER_NODE`, where `node_equivalent = node_count` if the instance is node-based, or `processing_units / 1000` if it is processing-unit-based (1000 PU == 1 node). The limit is never hardcoded to a single instance size.
- **Regional vs multi-region threshold**: Determined from the instance's `config` field — configs prefixed `regional-` are treated as regional (65% default ceiling); all other configs are treated as multi-region (45% default ceiling), per Google's lower recommended ceiling for multi-region deployments.
