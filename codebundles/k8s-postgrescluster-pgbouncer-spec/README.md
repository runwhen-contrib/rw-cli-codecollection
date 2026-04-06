# Kubernetes PostgresCluster PgBouncer Spec Audit

This CodeBundle validates Crunchy Postgres Operator (PGO) `PostgresCluster` custom resources for the **PgBouncer** proxy block: `poolMode`, connection limits (`max_client_conn`, `default_pool_size`, `max_db_connections`), and replica expectations. It complements runtime Prometheus health checks by auditing the declared GitOps/CRD source of truth.

## Overview

- **Fetch configuration**: Reads `postgresclusters.postgres-operator.crunchydata.com` and surfaces `spec.proxy.pgBouncer` plus related status.
- **Pool mode**: Compares `spec.proxy.pgBouncer.poolMode` to `EXPECTED_POOL_MODE` (transaction, session, or statement).
- **Connection limits**: Flags risky combinations when numeric limits are present in the PgBouncer config (nested paths supported across PGO versions).
- **Replicas**: Compares effective replicas (status, spec, or pgbouncer pod count) to `MIN_PGBOUNCER_REPLICAS`.
- **Prometheus (optional)**: When `PROMETHEUS_URL` is set, compares CR `max_client_conn` to `pgbouncer_config_max_client_connections` (best-effort label matching).

Confirm field names for your PGO version with `kubectl explain postgrescluster.spec.proxy.pgBouncer`.

## Configuration

### Required Variables

- `CONTEXT`: Kubernetes context name.
- `NAMESPACE`: Namespace containing the PostgresCluster.
- `POSTGRESCLUSTER_NAME`: PostgresCluster resource name, or `All` to audit every PostgresCluster in the namespace.
- `EXPECTED_POOL_MODE`: Expected pool mode string (`transaction`, `session`, or `statement`).

### Optional Variables

- `MIN_PGBOUNCER_REPLICAS`: Minimum acceptable PgBouncer replicas for policy (default: `1`).
- `PROMETHEUS_URL`: Base URL for Prometheus (no trailing path required); when empty, the cross-check task is a no-op.
- `KUBERNETES_DISTRIBUTION_BINARY`: CLI to use (`kubectl` or `oc`, default `kubectl`).

### Secrets

- `kubeconfig`: Kubernetes credentials with `get`/`list` on `PostgresCluster` and workloads (standard kubeconfig YAML).

## Tasks Overview

### Fetch PostgresCluster PgBouncer Configuration

Prints PgBouncer-related spec and status for each targeted cluster. Raises informational or warning issues if the CR cannot be read or PgBouncer is not declared under `spec.proxy.pgBouncer`.

### Validate Pool Mode Matches Expected

Raises issues when `poolMode` is missing or does not match `EXPECTED_POOL_MODE` (for example session mode when transaction is required for an ORM).

### Validate Connection Limit Consistency

When limit fields are present in config, flags cases such as `default_pool_size` exceeding `max_db_connections`, or `max_client_conn` lower than `default_pool_size`.

### Check PgBouncer Replica Count vs Service Expectations

Compares observed or declared replicas to `MIN_PGBOUNCER_REPLICAS` using status, spec, or pods labeled `postgres-operator.crunchydata.com/role=pgbouncer`.

### Optional Cross-Check CRD Limits with Live Prometheus Samples

If `PROMETHEUS_URL` is set, queries `pgbouncer_config_max_client_connections` and compares it to the CR `max_client_conn`. Skips cleanly when the URL is unset; PromQL may need tuning for your label schema.
