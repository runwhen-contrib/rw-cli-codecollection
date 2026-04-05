# Kubernetes PgBouncer Prometheus Health

This CodeBundle evaluates PgBouncer connection pool health using Prometheus metrics from [prometheus-community/pgbouncer_exporter](https://github.com/prometheus-community/pgbouncer_exporter) (or compatible forks). It aggregates signals across replicas, surfaces per-pod and per-database diagnostics, and supports an optional capacity planning ratio when application inputs are provided.

## Overview

- **Exporter availability**: treats `pgbouncer_up` and matching series as the source of truth for scrape and process health.
- **Saturation and waits**: compares client active (and optionally waiting) load to `pgbouncer_config_max_client_connections`, and flags wait queues and `client_maxwait_seconds` breaches.
- **Pool balance**: detects clients waiting while server-side idle capacity exists, and databases near `max_connections` with concurrent waits.
- **Configuration drift**: validates `pool_mode` from `pgbouncer_databases_*` labels against `EXPECTED_POOL_MODE`.
- **Hotspots and outliers**: ranks databases by `current_connections` and compares per-pod client load to the fleet median.
- **Growth and capacity**: uses `delta()` over a configurable window for leak-like growth; optional SLI compares estimated app demand to nominal PgBouncer capacity.

Pair with PostgreSQL backend health checks (for example `pg_stat_activity` vs `max_connections`) for end-to-end visibility.

## Configuration

### Required variables

- `PROMETHEUS_URL`: Base URL for Prometheus or Thanos (for example `https://prometheus.example.com` or including `/api/v1/`). Instant queries append `/api/v1/query` when needed.
- `PGBOUNCER_JOB_LABEL`: Label matcher fragment for the exporter without outer braces (for example `job="pgbouncer-exporter"` or `job=pgbouncer-exporter,instance=~".*"`).
- `EXPECTED_POOL_MODE`: Expected pool mode string as reported on metrics (`transaction`, `session`, or `statement`).

### Optional variables

- `CONTEXT`: Kubernetes context for paired workflows (optional if you only query Prometheus).
- `METRIC_NAMESPACE_FILTER`: Value for the namespace label when scoping series.
- `METRIC_NAMESPACE_LABEL`: Label name to use with `METRIC_NAMESPACE_FILTER` (default: `kubernetes_namespace`).
- `CLIENT_SATURATION_PERCENT_THRESHOLD`: Saturation percent threshold versus `max_client_conn` (default: `80`).
- `INCLUDE_WAITING_IN_SATURATION`: `true` or `false`; include waiting clients in saturation numerator (default: `true`).
- `CLIENT_WAITING_MIN_THRESHOLD`: Minimum summed waiting connections before raising an issue (default: `0`).
- `MAX_WAIT_SECONDS_THRESHOLD`: Maximum acceptable `pgbouncer_pools_client_maxwait_seconds` (default: `1`).
- `APP_REPLICAS`, `APP_DB_POOL_SIZE`, `PGBOUNCER_REPLICAS`: When all three are set, enables the capacity SLI task; otherwise that task skips analysis.
- `CONNECTION_GROWTH_LOOKBACK`: Range for `delta()` (default: `15m`).
- `CONNECTION_GROWTH_DELTA_THRESHOLD`: Total connection increase across the window that triggers growth issues (default: `8`).
- `POD_OUTLIER_RATIO`: Multiplier over the fleet median for per-pod client active load (default: `1.4`).
- `METRIC_POD_LABEL`: Prometheus label for pod identity on pool metrics (default: `pod`; use `kubernetes_pod_name` if that is how you scrape).
- `DATABASE_DOMINANCE_RATIO`: Share of total connections above which a single database is flagged (default: `0.45`).

### Secrets

- `prometheus_bearer_token`: Bearer token for the Prometheus HTTP API when authentication is required (plain text or OAuth token).
- `kubeconfig`: Optional kubeconfig for kubectl workflows outside this bundle; queries are Prometheus-first.

## Tasks overview

### Check PgBouncer Exporter and Process Availability

Fails when `pgbouncer_up` is zero for any series or when no series match the selector (scrape or label mismatch).

### Check Client Connection Saturation vs max_client_conn

Compares summed client load to `pgbouncer_config_max_client_connections` against `CLIENT_SATURATION_PERCENT_THRESHOLD`.

### Check Client Wait Queue Buildup

Raises when summed `pgbouncer_pools_client_waiting_connections` exceeds `CLIENT_WAITING_MIN_THRESHOLD`.

### Check Max Client Wait Time Spikes

Flags when `max(pgbouncer_pools_client_maxwait_seconds)` exceeds `MAX_WAIT_SECONDS_THRESHOLD`.

### Check Server Pool Balance vs Client Waits

Detects waiting clients alongside server idle capacity, and databases above roughly 85% of `max_connections` with waits.

### Validate Pool Mode from Metrics

Compares `pool_mode` labels on `pgbouncer_databases_current_connections` to `EXPECTED_POOL_MODE`.

### Analyze Per-Database Connection Distribution

Flags when a single database holds more than `DATABASE_DOMINANCE_RATIO` of summed `current_connections`.

### Aggregate Health Across PgBouncer Pods and Flag Outliers

Flags pods whose client active load exceeds the fleet median by `POD_OUTLIER_RATIO`.

### Detect Abnormal Client Connection Growth Rate

Uses `sum(delta(pgbouncer_pools_client_active_connections[...]))` against `CONNECTION_GROWTH_DELTA_THRESHOLD`.

### Compute Capacity Planning SLI

When optional replica and pool inputs are set, compares estimated demand to `max_client_conn * PGBOUNCER_REPLICAS` from metrics.
