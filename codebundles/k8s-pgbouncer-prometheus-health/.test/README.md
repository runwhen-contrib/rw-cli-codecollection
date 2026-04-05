# Testing k8s-pgbouncer-prometheus-health

This directory contains lightweight checks for the CodeBundle. Full validation requires a Prometheus endpoint with [pgbouncer_exporter](https://github.com/prometheus-community/pgbouncer_exporter) metrics.

## Prerequisites

- `bash`, `curl`, and `jq` available in the runner environment (matches the CodeBundle runtime).

## Quick start

```bash
task
```

This runs `bash -n` on all shell scripts in the parent directory.

## Manual integration test

Export `PROMETHEUS_URL` and `PGBOUNCER_JOB_LABEL`, optionally `METRIC_NAMESPACE_FILTER` and `prometheus_bearer_token`, then run individual scripts from the CodeBundle root and inspect the generated `check_*.json` files.
