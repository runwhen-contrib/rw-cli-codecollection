# Kubernetes PgBouncer Prometheus Health

Evaluates PgBouncer connection pool health using Prometheus metrics from `prometheus-community/pgbouncer_exporter` (or compatible scrapes), with cluster-wide aggregation and per-pod diagnostics. Tasks detect exporter outages, client saturation, wait queues, max wait spikes, pool imbalance versus idle servers, pool mode drift, per-database hotspots, replica skew, connection growth, and optional capacity ratios.

## Overview

This CodeBundle focuses on runtime signals exposed by the PgBouncer Prometheus exporter:

- **Exporter availability**: `pgbouncer_up` must be `1` for every scraped target.
- **Saturation and waits**: client active and waiting connections versus `pgbouncer_config_max_client_connections`, wait queue totals, and `pgbouncer_pools_client_maxwait_seconds`.
- **Balance and topology**: waiting clients while `server_idle_connections` remain, per-database share of `pgbouncer_databases_current_connections`, and per-pod load versus the fleet median.
- **Configuration drift**: `pool_mode` labels on database metrics versus `EXPECTED_POOL_MODE`.
- **Trends and capacity**: growth in aggregate client actives over a lookback window, and an optional demand/supply ratio when application and replica counts are provided.

Metric names follow prometheus-community `pgbouncer_exporter` v0.12.x; verify `/metrics` if you use a fork.

## Configuration

### Required Variables

- `PROMETHEUS_URL`: Base URL for the Prometheus or Thanos querier API (for example `https://prometheus.example/api/v1/`).
- `PGBOUNCER_JOB_LABEL`: Label matchers placed inside PromQL braces to select the PgBouncer exporter (for example `job="pgbouncer-exporter"` or `job="pgbouncer-exporter",namespace="db"`).
- `EXPECTED_POOL_MODE`: Expected pool mode: `transaction`, `session`, or `statement` (validated via `pool_mode` labels on database metrics).

### Optional Variables

- `METRIC_NAMESPACE_FILTER`: Kubernetes namespace value appended as `namespace="..."` in PromQL matchers (use when labels use `namespace` from kube SD).
- `CONTEXT`: Kubernetes context name for documentation or paired kubectl workflows (not required for PromQL-only tasks).
- `CLIENT_SATURATION_PERCENT_THRESHOLD`: Percent of `max_client_conn` at which saturation issues are raised (default: `80`).
- `MAX_WAIT_SECONDS_THRESHOLD`: Maximum acceptable `pgbouncer_pools_client_maxwait_seconds` (default: `1`).
- `CLIENT_WAITING_THRESHOLD`: Minimum summed `pgbouncer_pools_client_waiting_connections` to treat as buildup (default: `0.5`).
- `DATABASE_HOTSPOT_PERCENT_THRESHOLD`: Flag a database whose share of summed `pgbouncer_databases_current_connections` exceeds this percent (default: `40`).
- `POD_OUTLIER_DEVIATION_PERCENT`: Percent deviation from median per-pod load to flag an outlier (default: `50`).
- `CONNECTION_GROWTH_LOOKBACK_MINUTES`: Window for `query_range` growth analysis (default: `45`).
- `CONNECTION_GROWTH_ABSOLUTE_THRESHOLD`: Absolute increase in summed client active connections that triggers growth issues (default: `5`).
- `CAPACITY_SLI_WARN_RATIO`: Warn when estimated demand divided by supply is at or above this ratio (default: `0.85`).
- `APP_REPLICAS`: Application replica count for the optional capacity SLI task.
- `APP_DB_POOL_SIZE`: Per-replica application DB pool size for the optional capacity SLI task.
- `PGBOUNCER_REPLICAS`: PgBouncer replica count for the optional capacity SLI task.

### Secrets

- `prometheus_bearer_token`: Bearer token for authenticated Prometheus read APIs. Optional when Prometheus allows unauthenticated queries.

## Tasks Overview

### Check PgBouncer Exporter and Process Availability

Fails when `pgbouncer_up` is `0` for any series, indicating exporter failure or loss of access to PgBouncer.

### Check Client Connection Saturation vs max_client_conn

Computes per-pod utilization from pools metrics versus `pgbouncer_config_max_client_connections` and compares to `CLIENT_SATURATION_PERCENT_THRESHOLD`.

### Check Client Wait Queue Buildup

Raises an issue when summed `pgbouncer_pools_client_waiting_connections` exceeds `CLIENT_WAITING_THRESHOLD`.

### Check Max Client Wait Time Spikes

Evaluates `pgbouncer_pools_client_maxwait_seconds` by pod, database, and user against `MAX_WAIT_SECONDS_THRESHOLD`.

### Check Server Pool Balance vs Client Waits

Detects pools where clients are waiting while `pgbouncer_pools_server_idle_connections` is positive, suggesting misconfiguration or routing problems.

### Validate Pool Mode from Metrics

Compares `pool_mode` labels on `pgbouncer_databases_current_connections` to `EXPECTED_POOL_MODE`.

### Analyze Per-Database Connection Distribution

Flags databases whose share of summed current connections exceeds `DATABASE_HOTSPOT_PERCENT_THRESHOLD`.

### Aggregate Health Across PgBouncer Pods and Flag Outliers

Flags pods whose per-pod client active sum deviates from the median by at least `POD_OUTLIER_DEVIATION_PERCENT`.

### Detect Abnormal Client Connection Growth Rate

Uses a Prometheus range query over `CONNECTION_GROWTH_LOOKBACK_MINUTES` and compares the change in summed client actives to `CONNECTION_GROWTH_ABSOLUTE_THRESHOLD`.

### Compute Capacity Planning SLI (App Demand vs PgBouncer Capacity)

When `APP_REPLICAS`, `APP_DB_POOL_SIZE`, and `PGBOUNCER_REPLICAS` are all set, estimates demand versus `max(pgbouncer_config_max_client_connections) * PGBOUNCER_REPLICAS` and warns using `CAPACITY_SLI_WARN_RATIO`.

## Required Permissions

- **Prometheus**: Read access to `/api/v1/query` and `/api/v1/query_range` (GET/POST as configured). Use `prometheus_bearer_token` when RBAC or reverse proxies require authentication.

## Integration

Pair with PostgreSQL backend health checks (`pg_stat_activity` versus `max_connections`) and with CRD or manifest validation bundles for PgBouncer settings for full app → PgBouncer → PostgreSQL visibility.
