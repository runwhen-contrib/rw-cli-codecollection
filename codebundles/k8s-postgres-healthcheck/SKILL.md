---
name: k8s-postgres-healthcheck
description: Runs a series of tasks to check the overall health of a postgres cluster and to provide detailed information useful... Use when triaging or monitoring AKS, EKS, GKE workloads with skill template `k...
runtime:
  runbook: runbook.robot
  monitor: sli.robot
  runner: ro
platforms: [AKS, EKS, GKE, Kubernetes, Patroni, Postgres, Crunchy, Zalando]
resource_types: [kubernetes_resource]
access: read-only
---

# Kubernetes Postgres Healthcheck

## Summary

Runs a series of tasks to check the overall health of a postgres cluster and to provide detailed information useful for debugging or reviewing configurations.

See [README.md](README.md) for additional context.

## Tools

### List Resources Related to Postgres Cluster `${OBJECT_NAME}` in Namespace `${NAMESPACE}`

Runs a simple fetch all for the resources in the given workspace under the configured labels.

- **Robot task name**: <code>List Resources Related to Postgres Cluster `${OBJECT_NAME}` in Namespace `${NAMESPACE}`</code>
- **Robot file**: `runbook.robot`
- **Tags**: `access:read-only`, `postgres`, `resources`, `workloads`, `standard`, `information`, `data:config`
- **Reads**: `CONTEXT`, `KUBERNETES_DISTRIBUTION_BINARY`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Get Postgres Pod Logs & Events for Cluster `${OBJECT_NAME}` in Namespace `${NAMESPACE}`

Queries Postgres-related pods for their recent logs and checks for any warning-type events.

- **Robot task name**: <code>Get Postgres Pod Logs & Events for Cluster `${OBJECT_NAME}` in Namespace `${NAMESPACE}`</code>
- **Robot file**: `runbook.robot`
- **Tags**: `access:read-only`, `postgres`, `events`, `warnings`, `labels`, `logs`, `errors`, `pods`, `data:logs-bulk`
- **Reads**: `CONTEXT`, `KUBERNETES_DISTRIBUTION_BINARY`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Get Postgres Pod Resource Utilization for Cluster `${OBJECT_NAME}` in Namespace `${NAMESPACE}`

Performs and a top command on list of labeled postgres-related workloads to check pod resources.

- **Robot task name**: <code>Get Postgres Pod Resource Utilization for Cluster `${OBJECT_NAME}` in Namespace `${NAMESPACE}`</code>
- **Robot file**: `runbook.robot`
- **Tags**: `access:read-only`, `top`, `resources`, `utilization`, `database`, `workloads`, `cpu`, `memory`, `allocation`, `postgres`, `data:config`
- **Reads**: `CONTEXT`, `KUBERNETES_DISTRIBUTION_BINARY`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Check PostgreSQL Connection Health for Cluster `${OBJECT_NAME}` in Namespace `${NAMESPACE}`

Checks connection utilization, client connection summaries, and detects connection saturation issues. Prefers running queries from replicas for safety.

- **Robot task name**: <code>Check PostgreSQL Connection Health for Cluster `${OBJECT_NAME}` in Namespace `${NAMESPACE}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `connection_health.sh`
- **Tags**: `access:read-only`, `postgres`, `connections`, `utilization`, `health`, `clients`, `saturation`, `data:config`, `data:sql-query`
- **Reads**: `NAMESPACE`, `OBJECT_NAME`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Check PostgreSQL Core Metrics for Cluster `${OBJECT_NAME}` in Namespace `${NAMESPACE}`

Checks storage utilization, database sizes, table bloat, WAL usage, and other core PostgreSQL metrics.

- **Robot task name**: <code>Check PostgreSQL Core Metrics for Cluster `${OBJECT_NAME}` in Namespace `${NAMESPACE}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `core_metrics.sh`
- **Tags**: `access:read-only`, `postgres`, `storage`, `metrics`, `health`, `disk`, `wal`, `bloat`, `data:config`, `data:sql-query`
- **Reads**: `NAMESPACE`, `OBJECT_NAME`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Get Running Postgres Configuration for Cluster `${OBJECT_NAME}` in Namespace `${NAMESPACE}`

Fetches the postgres instance's configuration information.

- **Robot task name**: <code>Get Running Postgres Configuration for Cluster `${OBJECT_NAME}` in Namespace `${NAMESPACE}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `config_health.sh`
- **Tags**: `access:read-only`, `config`, `postgres`, `file`, `show`, `path`, `setup`, `configuration`, `data:config`, `data:sql-query`
- **Reads**: `NAMESPACE`, `OBJECT_NAME`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Get Patroni Output and Add to Report for Cluster `${OBJECT_NAME}` in Namespace `${NAMESPACE}`

Attempts to run the patronictl CLI within the workload if it's available to check the current state of a patroni cluster, if applicable.

- **Robot task name**: <code>Get Patroni Output and Add to Report for Cluster `${OBJECT_NAME}` in Namespace `${NAMESPACE}`</code>
- **Robot file**: `runbook.robot`
- **Tags**: `access:read-only`, `patroni`, `patronictl`, `list`, `cluster`, `health`, `check`, `state`, `postgres`, `data:config`
- **Reads**: `CONTEXT`, `KUBERNETES_DISTRIBUTION_BINARY`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Fetch Patroni Database Lag for Cluster `${OBJECT_NAME}` in Namespace `${NAMESPACE}`

Identifies the lag using patronictl and raises issues if necessary.

- **Robot task name**: <code>Fetch Patroni Database Lag for Cluster `${OBJECT_NAME}` in Namespace `${NAMESPACE}`</code>
- **Robot file**: `runbook.robot`
- **Tags**: `access:read-only`, `patroni`, `patronictl`, `list`, `cluster`, `health`, `postgres`, `lag`, `data:config`
- **Reads**: `CONTEXT`, `KUBERNETES_DISTRIBUTION_BINARY`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Check Database Backup Status for Cluster `${OBJECT_NAME}` in Namespace `${NAMESPACE}`

Checks the status of backup operations on Kubernets Postgres clusters. Raises issues if backups have not been completed or appear unhealthy.

- **Robot task name**: <code>Check Database Backup Status for Cluster `${OBJECT_NAME}` in Namespace `${NAMESPACE}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `backup_health.sh`
- **Tags**: `access:read-only`, `patroni`, `cluster`, `health`, `backup`, `database`, `postgres`, `data:config`, `data:sql-query`
- **Reads**: `NAMESPACE`, `OBJECT_NAME`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


## Monitor

Runs multiple Kubernetes and psql commands to report on the health of a postgres cluster. Produces a value between 0 (completely failing thet test) and 1 (fully passing the test). Checks for database lag & backup health.

- **Robot file**: `sli.robot`
- **Score range**: `0.0` (failing) to `1.0` (healthy)
- **Aggregation**: arithmetic mean of the sub-checks below
- **Recommended interval**: `180s`

### Sub-checks

#### Check Patroni Database Lag in Namespace `${NAMESPACE}` on Host `${HOSTNAME}` using `patronictl`

Identifies the lag using patronictl and raises issues if necessary.

- **Robot task name**: <code>Check Patroni Database Lag in Namespace `${NAMESPACE}` on Host `${HOSTNAME}` using `patronictl`</code>
- **Sub-metric name**: `database_lag`
- **Tags**: `patroni`, `patronictl`, `list`, `cluster`, `health`, `check`, `state`, `postgres`, `data:config`
- **Reads**: `CONTEXT`, `KUBERNETES_DISTRIBUTION_BINARY`


#### Check Database Backup Status for Cluster `${OBJECT_NAME}` in Namespace `${NAMESPACE}`

Ensure that backups are current and not stale.

- **Robot task name**: <code>Check Database Backup Status for Cluster `${OBJECT_NAME}` in Namespace `${NAMESPACE}`</code>
- **Sub-metric name**: `backup_status`
- **Underlying script**: `backup_health.sh`
- **Tags**: `patroni`, `cluster`, `health`, `backup`, `database`, `postgres`, `data:config`, `data:sql-query`
- **Reads**: —


## Inputs

| Name | Type | Description | Default | Required |
|---|---|---|---|---|
| `CONTEXT` | string | Which Kubernetes context to operate within. | — | yes |
| `KUBERNETES_DISTRIBUTION_BINARY` | string | Which binary to use for Kubernetes CLI commands. | `kubectl` | no |

## Secrets

_No secrets imported in Robot source._

## Outputs

- Monitor health score (`0.0`–`1.0`) pushed by `sli.robot`

## How to invoke

### Preferred: Robot Framework runner (`ro`)

```bash
cd codebundles/k8s-postgres-healthcheck
export CONTEXT=...
export KUBERNETES_DISTRIBUTION_BINARY=...
ro runbook.robot
```

### Standalone scripts (no Robot)


Set the input variables above, then run the matching script:

```bash
cd codebundles/k8s-postgres-healthcheck
export CONTEXT=...
export KUBERNETES_DISTRIBUTION_BINARY=...
bash backup_health.sh
bash config_health.sh
bash connection_health.sh
bash core_metrics.sh
bash dbquery.sh
```

## Source files

- `runbook.robot` — orchestrates tools and raises issues
- `sli.robot` — monitor scoring (`sli.robot` runtime file)
- `backup_health.sh` — Bash helper script `backup_health.sh`.
- `config_health.sh` — Bash helper script `config_health.sh`.
- `connection_health.sh` — Bash helper script `connection_health.sh`.
- `core_metrics.sh` — Bash helper script `core_metrics.sh`.
- `dbquery.sh` — Bash helper script `dbquery.sh`.
