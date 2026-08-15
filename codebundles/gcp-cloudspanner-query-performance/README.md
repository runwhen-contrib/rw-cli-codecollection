# GCP Cloud Spanner Query Performance

Monitors query-level performance of GCP Cloud Spanner databases by reading the built-in `SPANNER_SYS` introspection tables — surfacing high-latency queries, lock contention, transaction aborts, long-running queries, and CPU-heavy hot spots. This complements instance-level CPU/latency monitoring by pinpointing the specific queries and row-key ranges degrading a Spanner database, which aggregate metrics alone cannot identify.

## Overview

- **High-Latency Queries**: Queries `SPANNER_SYS.QUERY_STATS_TOP_*` ordered by mean latency and flags query shapes whose average latency exceeds the configured threshold.
- **Lock Contention**: Queries `SPANNER_SYS.LOCK_STATS_TOP_*` and flags contended row-key ranges whose accumulated lock wait time exceeds the threshold, reporting the sample lock-requesting columns/transactions.
- **Transaction Abort Rate**: Queries `SPANNER_SYS.TXN_STATS_TOP_*` and flags transaction shapes whose commit-abort rate exceeds the threshold, which usually indicates write contention or hotspotting.
- **Long-Running Queries**: Queries `SPANNER_SYS.OLDEST_ACTIVE_QUERIES` (a point-in-time table) and flags queries that have been actively running longer than the threshold.
- **CPU-Heavy Queries**: Queries `SPANNER_SYS.QUERY_STATS_TOP_*` ordered by total CPU time and flags query shapes consuming a disproportionate share of the top query shapes' combined CPU time (hot spots).
- **Query Performance Summary**: Produces a consolidated per-database JSON summary of the worst query shapes across latency, locks, and aborts, with an overall verdict (healthy/warning/critical), and raises a rollup issue for any non-healthy database.

## Configuration

### Required Variables

- `GCP_PROJECT_ID`: GCP Project ID containing the Cloud Spanner instances.

### Optional Variables

- `QUERY_LATENCY_THRESHOLD_MS`: Mean query latency (ms) above which a query is flagged (default: `100`).
- `LOCK_WAIT_THRESHOLD_MS`: Total lock wait time (ms) for a row-key range above which it is flagged (default: `1000`).
- `ABORT_RATE_THRESHOLD_PERCENT`: Transaction abort/commit-retry percent above which a transaction shape is flagged (default: `5`).
- `LONG_RUNNING_QUERY_THRESHOLD_SECONDS`: Elapsed time (s) above which an active query is flagged as long-running (default: `60`).
- `STATS_WINDOW`: SPANNER_SYS stats window granularity used to build table names -- `MINUTE`, `10MINUTE`, or `HOUR` (default: `HOUR`). Table names are built as `QUERY_STATS_TOP_<STATS_WINDOW>`, `LOCK_STATS_TOP_<STATS_WINDOW>`, `TXN_STATS_TOP_<STATS_WINDOW>`. `OLDEST_ACTIVE_QUERIES` has no window suffix and ignores this variable.
- `CPU_TIME_SHARE_THRESHOLD_PERCENT`: Share (percent) of the top query shapes' combined CPU time a single query shape can consume before it is flagged as a CPU hot spot (default: `25`).

### Secrets

- `gcp_credentials`: GCP service account JSON key for authentication. Format: JSON object containing `type`, `project_id`, `private_key_id`, `private_key`, `client_email`, `client_id`, `auth_uri`, `token_uri`. Requires `spanner.databases.select` (Spanner Database Reader or higher) on each database to read `SPANNER_SYS` via `execute-sql`.

## Tasks Overview

### Check Cloud Spanner High-Latency Queries
Queries `SPANNER_SYS.QUERY_STATS_TOP_*` ordered by average latency and flags query shapes whose mean latency exceeds `QUERY_LATENCY_THRESHOLD_MS`, reporting the query text and execution count.

### Check Cloud Spanner Lock Contention
Queries `SPANNER_SYS.LOCK_STATS_TOP_*` and flags contended row-key ranges with lock wait time above `LOCK_WAIT_THRESHOLD_MS`, reporting the sample lock-requesting columns.

### Check Cloud Spanner Transaction Abort Rate
Queries `SPANNER_SYS.TXN_STATS_TOP_*` and flags transaction shapes whose abort/commit-retry rate exceeds `ABORT_RATE_THRESHOLD_PERCENT`.

### Check Cloud Spanner Long-Running Queries
Queries `SPANNER_SYS.OLDEST_ACTIVE_QUERIES` and flags queries currently running longer than `LONG_RUNNING_QUERY_THRESHOLD_SECONDS`, reporting elapsed time and query text.

### Check Cloud Spanner CPU-Heavy Queries
Queries `SPANNER_SYS.QUERY_STATS_TOP_*` ordered by CPU time and flags queries consuming a disproportionate share of instance CPU (hot spots).

### Generate Cloud Spanner Query Performance Summary
Produces a consolidated per-database JSON summary of the worst query shapes across latency, locks, and aborts, with an overall verdict, and raises a rollup issue for any non-healthy database.

## SLI

`sli.robot` produces a 0-1 score aggregating five dimensions: high-latency queries, lock contention, transaction abort rate, long-running queries, and CPU-heavy queries (each a binary pass/fail, averaged). The query performance summary task is runbook-only (deep investigation), not part of the SLI, to keep the SLI lightweight.

## Requirements

The service account needs `spanner.databases.select` on each database being monitored (granted via `roles/spanner.databaseReader` or a broader role such as `roles/spanner.viewer`) so `gcloud spanner databases execute-sql` can read `SPANNER_SYS`.

## Platform Tools

- `gcloud spanner` - Google Cloud CLI Spanner commands, including `execute-sql` against `SPANNER_SYS`
- `jq` - JSON processor
- `python3` - Python runtime (numeric comparisons/formatting)

## Notes / Assumptions

- **SPANNER_SYS is queried per-database, not via instance metadata.** Every check uses `gcloud spanner databases execute-sql <database> --instance=<instance> --sql="..."` against the `SPANNER_SYS` schema of that specific database. Nothing in this bundle reads Cloud Monitoring metrics.
- **Empty result sets are expected and healthy.** `SPANNER_SYS.QUERY_STATS_TOP_*`, `LOCK_STATS_TOP_*`, and `TXN_STATS_TOP_*` are populated only from real traffic that occurred within the stats window. A database with no traffic in the window returns zero rows -- every script treats this as "no traffic to evaluate" and skips it silently, **not** as an issue. Only rows that are actually returned and exceed a configured threshold are flagged.
- **Table names are derived from `STATS_WINDOW`.** `QUERY_STATS_TOP_MINUTE` / `_10MINUTE` / `_HOUR`, `LOCK_STATS_TOP_*`, and `TXN_STATS_TOP_*` all follow this pattern. `OLDEST_ACTIVE_QUERIES` is a point-in-time table with no window suffix and is queried as-is.
- **CPU hot-spot detection is share-based, not absolute.** `check_cpu_heavy_queries.sh` computes each returned query shape's share of the combined CPU time of the top 20 query shapes (`AVG_CPU_SECONDS * EXECUTION_COUNT`) and flags shapes exceeding `CPU_TIME_SHARE_THRESHOLD_PERCENT`, since SPANNER_SYS does not expose instance-level CPU utilization directly (that lives in Cloud Monitoring and is covered by the sibling `gcp-cloudspanner-instance-health` bundle).
- **Resource type**: The `gcp_spanner_instances` identifier in `.runwhen/generation-rules/` is used **only by RunWhen Local** for auto-discovery/SLX generation. The runbook and SLI scripts discover instances and databases directly via `gcloud spanner instances list` / `gcloud spanner databases list`, so the CodeBundle runs standalone against any GCP project with no RunWhen Local dependency.
- **Related bundles**: `gcp-cloudspanner-instance-health` flags *that* an instance is slow/hot at the CPU/latency level (Cloud Monitoring); this bundle pinpoints *which* queries and row ranges cause it (SPANNER_SYS). `gcp-cloudspanner-backup-governance` is a sibling bundle covering data protection, with no check overlap.
