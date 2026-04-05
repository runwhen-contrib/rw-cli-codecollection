# Kubernetes PostgresCluster PgBouncer Spec Audit

This CodeBundle validates Crunchy Postgres Operator (PGO) `PostgresCluster` custom resources for the PgBouncer proxy block: pool mode, connection limits, replica expectations, and optional drift against Prometheus. It complements runtime metric checks by auditing declared GitOps or CRD configuration.

## Overview

- **Fetch configuration**: Reads `spec.proxy.pgBouncer` from the `PostgresCluster` CR (`postgres-operator.crunchydata.com/v1beta1`) and surfaces missing proxy configuration.
- **Pool mode**: Compares `spec.proxy.pgBouncer.config.global.pool_mode` to `EXPECTED_POOL_MODE` (transaction, session, statement).
- **Connection limits**: Flags risky combinations among `default_pool_size`, `max_client_conn`, and `max_db_connections` in the global PgBouncer configuration map.
- **Replicas**: Compares ready replicas (CR status and/or PgBouncer Deployment) to `MIN_PGBOUNCER_REPLICAS`.
- **Prometheus cross-check** (optional): When `PROMETHEUS_URL` and `PROMETHEUS_LABEL_SELECTOR` are set, compares CR `max_client_conn` to an instant query for `pgbouncer_config_max_client_connections` (name overridable).

Confirm JSONPath field names against your installed operator with `kubectl explain postgrescluster.spec.proxy.pgBouncer`.

## Configuration

### Required variables

- `CONTEXT`: Kubernetes context name.
- `NAMESPACE`: Namespace that contains the `PostgresCluster`.
- `POSTGRESCLUSTER_NAME`: Target `PostgresCluster` resource name, or `All` to evaluate every `PostgresCluster` in the namespace.
- `EXPECTED_POOL_MODE`: Expected `pool_mode` string (`transaction`, `session`, or `statement`).

### Optional variables

- `KUBERNETES_DISTRIBUTION_BINARY`: CLI to use (`kubectl` or `oc`, default `kubectl`).
- `MIN_PGBOUNCER_REPLICAS`: Minimum acceptable ready replicas for policy (default `1`).
- `PROMETHEUS_URL`: Base URL for Prometheus (e.g. `https://prometheus.example.com`); omit to skip the cross-check task.
- `PROMETHEUS_LABEL_SELECTOR`: Label selector inside metric braces for the instant query (for example `namespace="myns",kubernetes_pod_name=~"hippo-pgbouncer.*"`). Required for meaningful drift detection when `PROMETHEUS_URL` is set.
- `PROMETHEUS_MAX_CLIENT_CONN_METRIC`: Metric name for the instant query (default `pgbouncer_config_max_client_connections`).

### Secrets

- `kubeconfig`: Kubernetes credentials with `get`/`list` on `postgresclusters.postgres-operator.crunchydata.com`, Deployments, and related workloads.

## Tasks overview

### Fetch PostgresCluster PgBouncer Configuration

Prints the `spec.proxy.pgBouncer` object and raises issues if the CR cannot be read or PgBouncer is not configured.

### Validate Pool Mode Matches Expected

Raises an issue when `pool_mode` is missing or does not match `EXPECTED_POOL_MODE`.

### Validate Connection Limit Consistency

Raises issues when `max_db_connections` is below `default_pool_size`, or when `max_client_conn` is below `default_pool_size`.

### Check PgBouncer Replica Count

Raises an issue when observed ready replicas are below `MIN_PGBOUNCER_REPLICAS`.

### Optional Cross-Check CRD Limits with Live Prometheus Samples

Best-effort comparison of CR `max_client_conn` to Prometheus; skips when `PROMETHEUS_URL` is unset. The optional task expects `curl` for HTTP queries to the Prometheus API.
