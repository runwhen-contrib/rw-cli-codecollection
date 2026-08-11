# GCP Cloud Run Service Health

Monitors the operational health of GCP Cloud Run services in a single project.
It detects failed revisions, troubled or aborted rollouts, and services that are
not Ready or not able to serve traffic, and captures full service and revision
configuration so the report can be handed to an LLM for review. It uses the
`gcloud` command-line tool with a service account.

## Overview

This CodeBundle answers the question "is this Cloud Run service healthy right
now?" for every service in the scoped GCP project. It checks:

- **Failed revisions** — revisions whose `Ready` condition is not `True`
  (e.g. `ContainerStartupFailure`, `HealthCheckContainerFailed`,
  `ResourceExhausted`), surfacing revision name, service, generation, and the
  failing condition message.
- **Services Ready and serving** — the top-level `Ready` condition for each
  service, and whether traffic is actually routed to a Ready revision that can
  serve requests (flagging services serving 0% to the latest ready revision).
- **Troubled or aborted rollouts** — rollouts stuck in a non-Serving state:
  latest configuration not rolled out, rollback to a prior revision, or a
  configuration that has failed all generation attempts.
- **Error logs** — recent `ERROR`-level log entries
  (`resource.type=cloud_run_revision`) within a configurable lookback window.
- **Service and revision configuration** — full spec (annotations, concurrency,
  cpu/memory limits, env, service account, scaling) dumped to the report for
  LLM-based review, plus common configuration risks.

Services are auto-discovered per project via
`gcloud run services list --project=<project>`, or restricted to a specific
list via the `RESOURCES` variable.

## Configuration

### Required Variables

- `GCP_PROJECT_ID`: The GCP Project ID to scope the API to.

### Optional Variables

- `RESOURCES`: Comma-separated Cloud Run service names to check, or `All` for
  auto-discovery of every service in the project. (default: `All`)
- `ERROR_LOG_LOOKBACK`: Lookback window for error log queries, e.g. `14d`, `1d`,
  `6h`. (default: `14d`)

### Secrets

- `gcp_credentials`: GCP service account JSON used to authenticate with GCP
  APIs. Format: a JSON string, e.g.
  `{"type": "service_account", "project_id": "...", "client_email": "...", "private_key": "..."}`.

## Tasks Overview

### List Failed Cloud Run Revisions in GCP Project

Enumerates Cloud Run revisions whose `Ready` condition is not `True`, surfacing
revision name, service, generation, and the failing condition message. Raises an
issue per failing revision (severity 2 for most reasons, 3 for container startup
/ health-check / resource-exhaustion failures).

### Check Cloud Run Services Ready and Serving Traffic in GCP Project

Checks the top-level `Ready` condition for each service and verifies traffic is
routed to a Ready revision. Flags services that are not Ready (severity 2) or
serving 0% to the latest ready revision (severity 3).

### Detect Troubled or Aborted Cloud Run Rollouts in GCP Project

Identifies rollouts in a non-Serving state during a deploy window: latest
configuration not rolled out (generation not reconciled), a revision created but
never Ready, or a rollback to a prior revision. Reports the rollout status and
raises issues (severity 2-3).

### Get Error Logs for Unhealthy Cloud Run Services in GCP Project

Reads `ERROR`-level logs (`resource.type=cloud_run_revision`) for each service
within the `ERROR_LOG_LOOKBACK` window and raises an issue (severity 3) per
service with errors, including a summary of recent messages.

### Report Cloud Run Service and Revision Configuration in GCP Project

Dumps full service and revision configuration (spec, annotations, concurrency,
cpu/memory limits, env, service account, scaling) into the report for LLM review.
Also flags services using the default compute service account (severity 2) and
services with no maximum instance limit (severity 1, scaling cost risk).

## SLI

The `sli.robot` produces a binary 0-1 health score. It is 1 only if every health
dimension passes, 0 if any is degraded:

- **Revision health** — no failed (non-Ready) revisions
- **Serving health** — all services Ready with traffic on their latest ready
  revision
- **Rollout health** — no troubled or aborted rollouts

Each dimension is pushed as a sub-metric (with its raw issue count) and the
aggregate score is pushed as the primary metric.

## Requirements

The following permissions are required on the GCP service account used with the
`gcloud` utility:

- `run.services.get`
- `run.services.list`
- `run.revisions.list`
- `run.configurations.list`
- `logging.logEntries.list`
