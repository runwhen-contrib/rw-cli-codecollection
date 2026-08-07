# GCP Cloud Spanner Query Performance - Test Infrastructure

## Overview

This test infrastructure creates GCP Cloud Spanner instances and databases for testing the `gcp-cloudspanner-query-performance` CodeBundle, **and** drives real query traffic against them. This bundle is unusual among the collection's test fixtures: it reads `SPANNER_SYS.*` introspection tables, which are only populated from actual traffic that occurred within the stats window (`STATS_WINDOW`: MINUTE / 10MINUTE / HOUR). Terraform alone can provision the instance/database *shape*, but an empty database produces an empty `SPANNER_SYS` result set -- which the CodeBundle correctly treats as "no traffic," not "unhealthy." To exercise the detection logic at all, the fixture must also generate traffic.

## Test Scenarios

### healthy_workload
- Small regional Spanner instance (100 processing units) in `regional-<region>`.
- One database (`healthy_db_<suffix>`) with a single `Items` table.
- `task build-infra` provisions the shape; `task default` (or `generate-load` directly) then issues a handful of fast, uncontended `SELECT` statements against it via `gcloud spanner databases execute-sql`, well under every latency/lock/abort threshold.
- Expected issues: `0`.

### contended_workload
- Regional Spanner instance (100 processing units) also provisioned at the minimum tier, with one database (`contended_db_<suffix>`) containing a single-row `Counters` table.
- `generate-load` seeds the row, then fires **25 concurrent `UPDATE Counters SET Value = Value + 1 WHERE Id = 1` statements** via `gcloud` in parallel background processes. Spanner serializes writers to the same row under pessimistic locking, which reliably produces:
  - `LOCK_STATS_TOP_*` entries with elevated `LOCK_WAIT_SECONDS` on that row range, and
  - `TXN_STATS_TOP_*` entries with a non-zero `COMMIT_ABORT_COUNT` (Spanner aborts rather than blocking indefinitely under contention).
- Expected issues: `2` (severities `2`, `3`) -- one from `check_lock_contention.sh`, one from `check_transaction_aborts.sh` -- once the load step has run and the stats window has caught up (see Timing below).

## Prerequisites

1. GCP project with the Cloud Spanner API enabled.
2. Service account with permissions to create Cloud Spanner instances/databases and run DML (`roles/spanner.admin` for provisioning + `roles/spanner.databaseUser` or broader for `generate-load`'s inserts/updates; the CodeBundle itself only needs `roles/spanner.databaseReader` at runtime to read `SPANNER_SYS`).
3. `gcloud` CLI configured and authenticated (`generate-test-load.sh` shells out to it directly).

## Setup

1. Create `terraform/tf.secret` with:
   ```
   export GOOGLE_APPLICATION_CREDENTIALS="/path/to/service-account-key.json"
   export TF_VAR_project_id="your-gcp-project-id"
   ```

2. Provision the instances/databases and generate traffic:
   ```bash
   task build-infra
   task generate-load
   ```
   Or run the whole flow (infra + load + RunWhen Local discovery) with `task default`.

3. **Timing**: `SPANNER_SYS.QUERY_STATS_TOP_*`, `LOCK_STATS_TOP_*`, and `TXN_STATS_TOP_*` trail live traffic by roughly a minute. Wait ~60-90s after `generate-load` completes before running the runbook/SLI against the `MINUTE` or `10MINUTE` window. The default `HOUR` window has more headroom and does not need this wait.

4. Point the CodeBundle at the test project (`GCP_PROJECT_ID=$TF_VAR_project_id`) and run `runbook.robot` / `sli.robot` as usual, or re-run `task generate-load` before each test iteration to refresh the traffic window.

5. Clean up when done:
   ```bash
   task clean
   ```

## Notes

- `generate-load` is idempotent for the healthy-workload seed row and the counter row (it checks before inserting), so it is safe to re-run.
- If you need a longer or heavier contended workload (e.g. to push the abort rate higher for a stricter `ABORT_RATE_THRESHOLD_PERCENT`), increase the loop count in `../generate-test-load.sh`.
