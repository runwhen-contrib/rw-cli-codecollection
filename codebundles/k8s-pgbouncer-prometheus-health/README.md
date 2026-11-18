# Kubernetes PgBouncer Prometheus Health

This CodeBundle evaluates PgBouncer connection pool health using Prometheus metrics from the [prometheus-community/pgbouncer_exporter](https://github.com/prometheus-community/pgbouncer_exporter) (or compatible scrapes), with optional kubectl validation of `pool_mode` when a kubeconfig and namespace are supplied.

## Overview

- **Exporter and process availability**: detects `pgbouncer_up` failures per scrape target.
- **Saturation and waits**: compares active and waiting clients to `pgbouncer_config_max_client_connections`, flags wait queues, max wait time, and server-side balance patterns.
- **Configuration drift**: optional pool mode validation via metric labels or `pgbouncer.ini` read through kubectl.
- **Distribution and outliers**: ranks per-database load, highlights pod-level skew, and estimates capacity when app and pooler replica inputs are provided.
- **Growth**: uses Prometheus `rate()` over a configurable window to spot sustained connection growth.

## Configuration

### Required variables

- `PROMETHEUS_URL`: Base URL for the Prometheus or Thanos querier API (for example `https://prometheus.example/api/v1` or `https://thanos.example/api/v1`).
- `PGBOUNCER_JOB_LABEL`: Prometheus label matchers inside `{...}` for the exporter scrape, for example `job="pgbouncer-exporter"`.
- `EXPECTED_POOL_MODE`: Expected pool mode string: `transaction`, `session`, or `statement`.

### Optional variables

- `CONTEXT`: Kubernetes context for kubectl when kubeconfig is configured.
- `METRIC_NAMESPACE_FILTER`: Extra label matchers (comma-separated) such as `kubernetes_namespace="my-namespace"` to narrow series.
- `CLIENT_SATURATION_PERCENT_THRESHOLD`: Percent of `max_client_conn` above which saturation is raised (default `80`).
- `MAX_WAIT_SECONDS_THRESHOLD`: Maximum acceptable `pgbouncer_pools_client_maxwait_seconds` (default `1`).
- `CLIENT_WAITING_THRESHOLD`: Raise when the sum of waiting connections is greater than this value (default `0`).
- `DATABASE_HOTSPOT_PERCENT_THRESHOLD`: Flag databases whose share of connections exceeds this percent of the total (default `50`).
- `POD_OUTLIER_RATIO`: Flag pods whose per-pod client active sum exceeds the fleet mean times this ratio (default `2.0`).
- `GROWTH_RATE_WINDOW_MINUTES`: Lookback for Prometheus range queries used in growth detection (default `15`).
- `CONNECTION_GROWTH_RATE_THRESHOLD`: Average `rate()` of client active connections (per second) that triggers growth issues (default `0.1`).
- `KUBERNETES_DISTRIBUTION_BINARY`: CLI binary for kubectl (default `kubectl`).
- `PGBOUNCER_NAMESPACE`: Namespace used to locate a pod for optional pool mode inspection (often the same as the PgBouncer workload namespace).
- `PGBOUNCER_POD_LABEL_SELECTOR`: Label selector for the pod that mounts `pgbouncer.ini` (default `app.kubernetes.io/name=pgbouncer-exporter`; change to your PgBouncer pod labels if the exporter runs as a sidecar elsewhere).
- `PGBOUNCER_PGBOUNCER_CONTAINER`: Optional container name for `kubectl exec` when the pod is multi-container.
- `APP_REPLICAS`: Application replica count for the capacity SLI (optional).
- `APP_DB_POOL_SIZE`: Per-replica application DB pool size for the capacity SLI (optional).
- `PGBOUNCER_REPLICAS`: PgBouncer replica count for the capacity SLI (optional).

### Secrets

- `prometheus_bearer_token`: Bearer token for authenticated Prometheus read APIs when required (plain text or OAuth token).
- `kubeconfig`: Standard kubeconfig used for optional kubectl-based pool mode checks.

## Tasks overview

### Check PgBouncer Exporter and Process Availability

Fails when `pgbouncer_up` is `0` for any filtered target or when no series are returned.

### Check Client Connection Saturation vs max_client_conn

Compares `(sum(client_active) + sum(client_waiting)) / max(max_client_conn)` to the percent threshold.

### Check Client Wait Queue Buildup

Raises when the sum of `pgbouncer_pools_client_waiting_connections` is above `CLIENT_WAITING_THRESHOLD`.

### Check Max Client Wait Time Spikes

Compares `max(pgbouncer_pools_client_maxwait_seconds)` to `MAX_WAIT_SECONDS_THRESHOLD`.

### Check Server Pool Balance vs Client Waits

Flags clients waiting while server idle connections exist, and clients waiting alongside elevated `server_used` counts.

### Validate Pool Mode from Metrics or Config

Prefers a `pool_mode` label on metrics if present; otherwise attempts to read `pool_mode` from common `pgbouncer.ini` paths via kubectl when `PGBOUNCER_NAMESPACE` and kubeconfig are set.

### Analyze Per-Database Connection Distribution

Uses `pgbouncer_databases_current_connections` when available, otherwise `pgbouncer_pools_client_active_connections` by `database` label, to find hotspots.

### Aggregate Health Across PgBouncer Pods and Flag Outliers

Compares per-pod `sum(client_active)` against the fleet mean using `POD_OUTLIER_RATIO`.

### Detect Abnormal Client Connection Growth Rate

Runs a range query on `rate(pgbouncer_pools_client_active_connections[5m])` and compares average rates to `CONNECTION_GROWTH_RATE_THRESHOLD`.

### Compute Capacity Planning SLI (App Demand vs PgBouncer Capacity)

When `APP_REPLICAS`, `APP_DB_POOL_SIZE`, and `PGBOUNCER_REPLICAS` are all set, compares `APP_REPLICAS * APP_DB_POOL_SIZE` to `max(pgbouncer_config_max_client_connections) * PGBOUNCER_REPLICAS`.
