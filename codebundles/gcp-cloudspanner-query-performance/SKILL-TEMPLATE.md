---
name: gcp-cloudspanner-query-performance
kind: skill-template
description: Monitors GCP Cloud Spanner query-level performance via the SPANNER_SYS introspection tables — high-latency queries, lock contention, transaction aborts, long-running queries, and CPU-heavy hot spots. Use when triaging or monitoring Cloud Spanner query performance.
runtime:
  runbook: runbook.robot
  monitor: sli.robot
  executor: worker
  entrypoint: /home/runwhen/robot-runtime/runrobot.sh
  base_image: rw-base-runtime
platforms: [GCP, Spanner]
resource_types: [gcp_resource]
access: read-only
---

# GCP Cloud Spanner Query Performance

## Summary

Monitors query-level performance of GCP Cloud Spanner databases by reading the built-in `SPANNER_SYS` introspection tables — surfacing high-latency queries, lock contention, transaction aborts, long-running queries, and CPU-heavy hot spots.

See [README.md](README.md) for additional context.

## Tools

### Check Cloud Spanner High-Latency Queries for `${GCP_PROJECT_ID}`

Queries SPANNER_SYS.QUERY_STATS_TOP_* ordered by average latency and flags query shapes whose mean latency exceeds the threshold, reporting the query text and execution count.

- **Robot task name**: <code>Check Cloud Spanner High-Latency Queries for `${GCP_PROJECT_ID}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `check_high_latency_queries.sh`
- **Tags**: `gcp`, `spanner`, `query`, `latency`, `data:metrics`, `access:read-only`
- **Reads**: —
- **Writes**: `high_latency_queries_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Check Cloud Spanner Lock Contention for `${GCP_PROJECT_ID}`

Queries SPANNER_SYS.LOCK_STATS_TOP_* and flags contended row-key ranges with lock wait time above the threshold, reporting the sample lock-requesting columns.

- **Robot task name**: <code>Check Cloud Spanner Lock Contention for `${GCP_PROJECT_ID}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `check_lock_contention.sh`
- **Tags**: `gcp`, `spanner`, `query`, `locks`, `contention`, `data:metrics`, `access:read-only`
- **Reads**: —
- **Writes**: `lock_contention_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Check Cloud Spanner Transaction Abort Rate for `${GCP_PROJECT_ID}`

Queries SPANNER_SYS.TXN_STATS_TOP_* and flags transaction shapes whose abort or commit-retry rate exceeds the threshold, which indicates contention or hotspotting.

- **Robot task name**: <code>Check Cloud Spanner Transaction Abort Rate for `${GCP_PROJECT_ID}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `check_transaction_aborts.sh`
- **Tags**: `gcp`, `spanner`, `query`, `transactions`, `aborts`, `data:metrics`, `access:read-only`
- **Reads**: —
- **Writes**: `transaction_aborts_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Check Cloud Spanner Long-Running Queries for `${GCP_PROJECT_ID}`

Queries SPANNER_SYS.OLDEST_ACTIVE_QUERIES and flags queries currently running longer than the threshold, reporting elapsed time and query text.

- **Robot task name**: <code>Check Cloud Spanner Long-Running Queries for `${GCP_PROJECT_ID}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `check_long_running_queries.sh`
- **Tags**: `gcp`, `spanner`, `query`, `long-running`, `data:metrics`, `access:read-only`
- **Reads**: —
- **Writes**: `long_running_queries_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Check Cloud Spanner CPU-Heavy Queries for `${GCP_PROJECT_ID}`

Queries SPANNER_SYS.QUERY_STATS_TOP_* ordered by CPU time and flags queries consuming a disproportionate share of instance CPU (hot spots).

- **Robot task name**: <code>Check Cloud Spanner CPU-Heavy Queries for `${GCP_PROJECT_ID}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `check_cpu_heavy_queries.sh`
- **Tags**: `gcp`, `spanner`, `query`, `cpu`, `data:metrics`, `access:read-only`
- **Reads**: —
- **Writes**: `cpu_heavy_queries_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


## Monitor

Measures Cloud Spanner query-level performance by scoring high-latency queries, lock contention, transaction abort rate, long-running queries, and CPU-heavy query hot spots read from SPANNER_SYS. Produces a value between 0 (completely failing) and 1 (fully passing).

- **Robot file**: `sli.robot`
- **Score range**: `0.0` (failing) to `1.0` (healthy)
- **Aggregation**: arithmetic mean of the sub-checks below
- **Recommended interval**: `180s`

### Sub-checks

#### Score Cloud Spanner High-Latency Queries for `${GCP_PROJECT_ID}`

Scores query latency against SPANNER_SYS.QUERY_STATS_TOP_*. Returns 1 if no query shape exceeds the latency threshold.

- **Robot task name**: <code>Score Cloud Spanner High-Latency Queries for `${GCP_PROJECT_ID}`</code>
- **Sub-metric name**: `high_latency_queries`
- **Underlying script**: `check_high_latency_queries.sh`
- **Tags**: `gcp`, `spanner`, `query`, `latency`, `data:metrics`, `access:read-only`
- **Reads**: —
- **Pass condition**: `int(${issues_output.stdout}) == 0`


#### Score Cloud Spanner Lock Contention for `${GCP_PROJECT_ID}`

Scores lock contention against SPANNER_SYS.LOCK_STATS_TOP_*. Returns 1 if no row-key range exceeds the lock-wait threshold.

- **Robot task name**: <code>Score Cloud Spanner Lock Contention for `${GCP_PROJECT_ID}`</code>
- **Sub-metric name**: `lock_contention`
- **Underlying script**: `check_lock_contention.sh`
- **Tags**: `gcp`, `spanner`, `query`, `locks`, `data:metrics`, `access:read-only`
- **Reads**: —
- **Pass condition**: `int(${issues_output.stdout}) == 0`


#### Score Cloud Spanner Transaction Abort Rate for `${GCP_PROJECT_ID}`

Scores transaction abort rate against SPANNER_SYS.TXN_STATS_TOP_*. Returns 1 if no transaction shape exceeds the abort-rate threshold.

- **Robot task name**: <code>Score Cloud Spanner Transaction Abort Rate for `${GCP_PROJECT_ID}`</code>
- **Sub-metric name**: `transaction_aborts`
- **Underlying script**: `check_transaction_aborts.sh`
- **Tags**: `gcp`, `spanner`, `query`, `transactions`, `data:metrics`, `access:read-only`
- **Reads**: —
- **Pass condition**: `int(${issues_output.stdout}) == 0`


#### Score Cloud Spanner Long-Running Queries for `${GCP_PROJECT_ID}`

Scores active query age against SPANNER_SYS.OLDEST_ACTIVE_QUERIES. Returns 1 if no active query exceeds the long-running threshold.

- **Robot task name**: <code>Score Cloud Spanner Long-Running Queries for `${GCP_PROJECT_ID}`</code>
- **Sub-metric name**: `long_running_queries`
- **Underlying script**: `check_long_running_queries.sh`
- **Tags**: `gcp`, `spanner`, `query`, `long-running`, `data:metrics`, `access:read-only`
- **Reads**: —
- **Pass condition**: `int(${issues_output.stdout}) == 0`


#### Score Cloud Spanner CPU-Heavy Queries for `${GCP_PROJECT_ID}`

Scores CPU-time concentration against SPANNER_SYS.QUERY_STATS_TOP_*. Returns 1 if no query shape is a disproportionate CPU hot spot.

- **Robot task name**: <code>Score Cloud Spanner CPU-Heavy Queries for `${GCP_PROJECT_ID}`</code>
- **Sub-metric name**: `cpu_heavy_queries`
- **Underlying script**: `check_cpu_heavy_queries.sh`
- **Tags**: `gcp`, `spanner`, `query`, `cpu`, `data:metrics`, `access:read-only`
- **Reads**: —
- **Pass condition**: `int(${issues_output.stdout}) == 0`


## Inputs

| Name | Type | Description | Default | Required |
|---|---|---|---|---|
| `GCP_PROJECT_ID` | string | GCP Project ID containing the Cloud Spanner instances. | — | yes |
| `QUERY_LATENCY_THRESHOLD_MS` | string | Mean query latency (ms) above which a query is flagged. | `100` | no |
| `LOCK_WAIT_THRESHOLD_MS` | string | Total lock wait time (ms) for a row range above which it is flagged. | `1000` | no |
| `ABORT_RATE_THRESHOLD_PERCENT` | string | Transaction abort/commit-retry percent above which a transaction shape is flagged. | `5` | no |
| `LONG_RUNNING_QUERY_THRESHOLD_SECONDS` | string | Elapsed time (s) above which an active query is flagged as long-running. | `60` | no |
| `STATS_WINDOW` | string | SPANNER_SYS stats window granularity used to build table names (QUERY_STATS_TOP_<window>, etc). | `HOUR` | no |
| `CPU_TIME_SHARE_THRESHOLD_PERCENT` | string | Share (percent) of the top query shapes' combined CPU time a single query shape can consume before it is flagged as a CPU hot spot. | `25` | no |

## Secrets

| Name | Description | Required |
|---|---|---|
| `gcp_credentials` | GCP service account JSON key used to authenticate with GCP APIs. Requires Spanner Database Reader (spanner.databases.select) to read SPANNER_SYS via execute-sql. | yes |

## Outputs

- Monitor health score (`0.0`–`1.0`) pushed by `sli.robot`
- `high_latency_queries_issues.json`
- `lock_contention_issues.json`
- `transaction_aborts_issues.json`
- `long_running_queries_issues.json`
- `cpu_heavy_queries_issues.json`

## How to invoke

### Production (RunWhen runner / worker)

The platform **runner** schedules work on a location **worker**. The worker
image (`rw-base-runtime`) executes Robot via `runrobot.sh` with
`RW_PATH_TO_ROBOT` set to the bound path under `/home/runwhen/collection/`.

- **Runbook**: `codebundles/gcp-cloudspanner-query-performance/runbook.robot`
- **Monitor**: `codebundles/gcp-cloudspanner-query-performance/sli.robot`

### Local development (devcontainer only)

`ro` is a dev-time wrapper in `codecollection-devtools` — not the enterprise runtime.

```bash
cd codebundles/gcp-cloudspanner-query-performance
export GCP_PROJECT_ID=...
export QUERY_LATENCY_THRESHOLD_MS=...
export LOCK_WAIT_THRESHOLD_MS=...
export ABORT_RATE_THRESHOLD_PERCENT=...
export LONG_RUNNING_QUERY_THRESHOLD_SECONDS=...
ro runbook.robot
```

### Standalone scripts (no Robot)


Set the input variables above, then run the matching script:

```bash
cd codebundles/gcp-cloudspanner-query-performance
export GCP_PROJECT_ID=...
export QUERY_LATENCY_THRESHOLD_MS=...
export LOCK_WAIT_THRESHOLD_MS=...
bash check_cpu_heavy_queries.sh
bash check_high_latency_queries.sh
bash check_lock_contention.sh
bash check_long_running_queries.sh
bash check_transaction_aborts.sh
```

## Source files

- `runbook.robot` — orchestrates tools and raises issues
- `sli.robot` — monitor scoring (`sli.robot` runtime file)
- `check_cpu_heavy_queries.sh` — Bash helper script `check_cpu_heavy_queries.sh`.
- `check_high_latency_queries.sh` — Bash helper script `check_high_latency_queries.sh`.
- `check_lock_contention.sh` — Bash helper script `check_lock_contention.sh`.
- `check_long_running_queries.sh` — Bash helper script `check_long_running_queries.sh`.
- `check_transaction_aborts.sh` — Bash helper script `check_transaction_aborts.sh`.
