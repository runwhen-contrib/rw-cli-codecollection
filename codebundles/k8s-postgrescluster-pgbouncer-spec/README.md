# Kubernetes PostgresCluster PgBouncer Spec Audit

This CodeBundle validates Crunchy Postgres Operator (PGO) `PostgresCluster` custom resources for the PgBouncer proxy: `spec.proxy.pgBouncer.config.global` keys such as `pool_mode`, `default_pool_size`, `max_client_conn`, and `max_db_connections`, plus replica expectations. It complements runtime Prometheus health checks by auditing declared GitOps configuration.

## Overview

- **Fetch**: Reads each targeted `PostgresCluster` and summarizes PgBouncer global settings; reports when the proxy block is missing or the CR cannot be read.
- **Pool mode**: Compares `pool_mode` to `EXPECTED_POOL_MODE` (transaction, session, or statement).
- **Connection limits**: Flags inconsistent numeric combinations (for example `max_db_connections` below `default_pool_size`).
- **Replicas**: Compares desired and ready PgBouncer replicas to `MIN_PGBOUNCER_REPLICAS`.
- **Prometheus (optional)**: When `PROMETHEUS_URL` is set, compares CR `max_client_conn` to `pgbouncer_config_max_client_connections` samples.

PGO stores PgBouncer options under `spec.proxy.pgBouncer.config.global` as `pgbouncer.ini`-style keys (underscore names). Confirm field paths with `kubectl explain postgrescluster.spec.proxy.pgBouncer` on your operator version.

## Configuration

### Required Variables

- `CONTEXT`: Kubernetes context name.
- `NAMESPACE`: Namespace containing the `PostgresCluster`.
- `POSTGRESCLUSTER_NAME`: Name of the `PostgresCluster` CR, or `All` to evaluate every `PostgresCluster` in the namespace.
- `EXPECTED_POOL_MODE`: Expected `pool_mode` string (`transaction`, `session`, or `statement`).

### Optional Variables

- `MIN_PGBOUNCER_REPLICAS`: Minimum acceptable PgBouncer replicas for policy (default: `1`).
- `PROMETHEUS_URL`: Base URL for Prometheus (for example `http://prometheus:9090`). Leave empty to skip the cross-check task.
- `PROMETHEUS_EXTRA_LABELS`: Extra PromQL label selectors appended inside the `pgbouncer_config_max_client_connections` selector (for example `pod=~"hippo.*"`). Optional.
- `KUBERNETES_DISTRIBUTION_BINARY`: CLI binary (default: `kubectl`).

### Secrets

- `kubeconfig`: Kubernetes credentials with `get`/`list` on `postgresclusters.postgres-operator.crunchydata.com` and related workloads. Format: kubeconfig YAML.

## Tasks Overview

### Fetch PostgresCluster PgBouncer Configuration

Loads the CR and prints PgBouncer global settings. Raises issues when the cluster cannot be read, when `POSTGRESCLUSTER_NAME=All` finds no clusters, or when `spec.proxy.pgBouncer` is absent.

### Validate Pool Mode Matches Expected

Compares configured `pool_mode` to `EXPECTED_POOL_MODE` for ORM-appropriate pooling.

### Validate Connection Limit Consistency

Checks relationships between `default_pool_size`, `max_client_conn`, and `max_db_connections` and flags impossible or risky combinations.

### Check PgBouncer Replica Count vs Policy

Compares `spec.proxy.pgBouncer.replicas` and `status.proxy.pgBouncer.readyReplicas` to `MIN_PGBOUNCER_REPLICAS`.

### Optional Cross-Check CRD Limits with Live Prometheus Samples

When `PROMETHEUS_URL` is set, runs an instant query for `pgbouncer_config_max_client_connections` in the namespace and compares it to the CR `max_client_conn`.
