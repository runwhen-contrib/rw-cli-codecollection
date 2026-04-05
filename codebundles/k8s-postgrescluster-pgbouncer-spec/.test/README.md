# Testing k8s-postgrescluster-pgbouncer-spec

Integration tests require a Kubernetes cluster with the Crunchy Postgres Operator and at least one `PostgresCluster` that defines `spec.proxy.pgBouncer`.

## Prerequisites

- `kubectl`, `jq`, and optional `curl` (for the Prometheus cross-check task)
- Kubeconfig with read access to `postgresclusters.postgres-operator.crunchydata.com` and Deployments

## Manual smoke test

From this CodeBundle directory, with kubeconfig exported:

```bash
export CONTEXT=your-context NAMESPACE=your-ns POSTGRESCLUSTER_NAME=your-cluster
export EXPECTED_POOL_MODE=transaction MIN_PGBOUNCER_REPLICAS=1
export KUBECONFIG=/path/to/kubeconfig
./fetch-postgrescluster-pgbouncer.sh
./validate-pool-mode.sh
```

Review the generated `*_issues.json` files and script stdout.
