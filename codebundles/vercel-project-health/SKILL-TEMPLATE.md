---
name: vercel-project-health
kind: skill-template
description: Vercel project health — project configuration snapshot, recent deployments with git branches, and unhealthy HTTP... Use when triaging or monitoring Vercel, HTTP, logs workloads with skill template ...
runtime:
  runbook: runbook.robot
  monitor: sli.robot
  executor: worker
  entrypoint: /home/runwhen/robot-runtime/runrobot.sh
  base_image: rw-base-runtime
platforms: [Vercel, HTTP, logs, runtime, project, deployments]
resource_types: []
access: read-only
---

# Vercel Project Health

## Summary

This CodeBundle inspects a Vercel project end-to-end: **project configuration** (sanitized), **recent deployments with git branches** and production readiness hints, **failed-deployment diagnostics** (real build error reasons), **production domain verification**, **historical HTTP traffic** (4xx, 5xx, optional codes) by route over a lookback window, and a complementary **synthetic HTTP probe**....

See [README.md](README.md) for additional context.

## Tools

### Fetch Vercel Project Configuration for Configured Project(s)

GET /v9/projects — writes sanitized project metadata per project under VERCEL_ARTIFACT_DIR (see suite vars).

- **Robot task name**: <code>Fetch Vercel Project Configuration for Configured Project(s)</code>
- **Robot file**: `runbook.robot`
- **Tags**: `Vercel`, `config`, `access:read-only`, `data:logs-config`
- **Reads**: —
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Report Vercel Deployment Branches and Status for Configured Project(s)

Lists recent production and preview deployments (all targets), git branch and commit metadata, and summary hints such as latest production READY state.

- **Robot task name**: <code>Report Vercel Deployment Branches and Status for Configured Project(s)</code>
- **Robot file**: `runbook.robot`
- **Tags**: `Vercel`, `deployments`, `git`, `access:read-only`, `data:logs-config`
- **Reads**: —
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Diagnose Recent Failed Vercel Deployments for Configured Project(s)

For each ERROR/CANCELED entry in the deployment-branches snapshot (capped by MAX_FAILED_DEPLOYMENTS_TO_DIAGNOSE), pulls GET /v13/deployments/{id} and surfaces the actual errorCode + errorMessage + branch + commit so on-call sees the real failure reason instead of just a count.

- **Robot task name**: <code>Diagnose Recent Failed Vercel Deployments for Configured Project(s)</code>
- **Robot file**: `runbook.robot`
- **Tags**: `Vercel`, `deployments`, `diagnose`, `access:read-only`, `data:logs-config`
- **Reads**: —
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Verify Vercel Project Production Domains for Configured Project(s)

Calls GET /v9/projects/{id}/domains, separates production-bound hostnames from preview/custom-environment aliases, reports verification + redirect state, and raises one issue per unverified production domain (with the TXT/CNAME records the user needs to add).

- **Robot task name**: <code>Verify Vercel Project Production Domains for Configured Project(s)</code>
- **Robot file**: `runbook.robot`
- **Tags**: `Vercel`, `domains`, `access:read-only`, `data:logs-config`
- **Reads**: —
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Resolve Vercel Deployments in Time Window for Configured Project(s)

Lists deployments whose active interval overlaps the lookback window so log queries use relevant deployment IDs and warns when none cover the window.

- **Robot task name**: <code>Resolve Vercel Deployments in Time Window for Configured Project(s)</code>
- **Robot file**: `runbook.robot`
- **Tags**: `Vercel`, `deployment`, `access:read-only`, `data:logs-config`
- **Reads**: —
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Collect Vercel Request Logs for Configured Project(s)

Hits Vercel's historical request-logs endpoint (the same one the dashboard's "Logs" page uses) for the lookback window, paginates rows, and writes vercel_request_log_rows.json. The 4xx / 5xx / other aggregate tasks read this file directly instead of issuing more API calls. Filtered to VERCEL_REQUEST_LOGS_ENV (default: production) so we only score what real users hit.

- **Robot task name**: <code>Collect Vercel Request Logs for Configured Project(s)</code>
- **Robot file**: `runbook.robot`
- **Tags**: `Vercel`, `HTTP`, `logs`, `access:read-only`, `data:logs`
- **Reads**: —
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Aggregate 4xx Paths from Vercel Request Logs for Configured Project(s)

Reads the shared request-log rows and aggregates ALL 4xx responses (400-499) by code, path, and method. Surfaces 401/403/422/etc. that a 404-only filter would drop.

- **Robot task name**: <code>Aggregate 4xx Paths from Vercel Request Logs for Configured Project(s)</code>
- **Robot file**: `runbook.robot`
- **Tags**: `Vercel`, `HTTP`, `4xx`, `access:read-only`, `data:logs`
- **Reads**: —
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Aggregate 5xx Paths from Vercel Request Logs for Configured Project(s)

Aggregates server-side HTTP errors (5xx) by code, path, and method from the shared request-log rows.

- **Robot task name**: <code>Aggregate 5xx Paths from Vercel Request Logs for Configured Project(s)</code>
- **Robot file**: `runbook.robot`
- **Tags**: `Vercel`, `HTTP`, `5xx`, `access:read-only`, `data:logs`
- **Reads**: —
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Aggregate Other Unhealthy HTTP Codes from Vercel Request Logs for Configured Project(s)

Aggregates additional client error codes configured in UNHEALTHY_HTTP_CODES (for example 408 and 429) by code, path, and method from the shared request-log rows.

- **Robot task name**: <code>Aggregate Other Unhealthy HTTP Codes from Vercel Request Logs for Configured Project(s)</code>
- **Robot file**: `runbook.robot`
- **Tags**: `Vercel`, `HTTP`, `errors`, `access:read-only`, `data:logs`
- **Reads**: —
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Build Consolidated Vercel HTTP Error Summary for Configured Project(s)

Merges per-code summaries, applies MIN_REQUEST_COUNT_THRESHOLD for noise reduction, and emits consolidated JSON plus a top-routes table for reporting.

- **Robot task name**: <code>Build Consolidated Vercel HTTP Error Summary for Configured Project(s)</code>
- **Robot file**: `runbook.robot`
- **Tags**: `Vercel`, `HTTP`, `summary`, `access:read-only`, `data:logs`
- **Reads**: —
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Probe Production URL Paths for Configured Project(s)

Synthetic HTTP GET probe against configurable paths on the latest production URL. Catches what historical logs miss (DNS / cert / cold-start timeouts, regional CDN issues, no-traffic blind spots) and complements the request-logs aggregations. Configure VERCEL_PROBE_PATHS, VERCEL_PROBE_BASE_URL (optional override), VERCEL_PROBE_TIMEOUT_SECONDS, VERCEL_PROBE_SLOW_MS.

- **Robot task name**: <code>Probe Production URL Paths for Configured Project(s)</code>
- **Robot file**: `runbook.robot`
- **Tags**: `Vercel`, `HTTP`, `probe`, `access:read-only`, `data:probe`
- **Reads**: —
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


## Monitor

Measures Vercel project health across eight binary sub-signals — API reachability, latest production deployment READY, recent deployment failure ratio, production-branch match, latest production deployment fresh, production alias is current (no rollback in progress), production domains verified, and a capped runtime HTTP error sample. Averages them into a primary score between 0 (failing) and 1 (healthy).

- **Robot file**: `sli.robot`
- **Score range**: `0.0` (failing) to `1.0` (healthy)
- **Aggregation**: arithmetic mean of the sub-checks below
- **Recommended interval**: `180s`

### Sub-checks

#### Score Vercel Project API Reachability

Binary score: 1 when GET /v9/projects/{id} returns the configured project for the current token + team scope, 0 otherwise.

- **Robot task name**: <code>Score Vercel Project API Reachability</code>
- **Sub-metric name**: `vercel_api_ok`
- **Tags**: `Vercel`, `sli`, `access:read-only`, `data:metrics`
- **Reads**: `VERCEL_PROJECT_ID`, `VERCEL_TEAM_ID`


#### Score Vercel Deployment Health Signals

Five lightweight signals derived from a single GET /v9/projects/{id} call: latest production deployment is READY; recent ERROR/CANCELED count is at or below SLI_MAX_RECENT_FAILED_DEPLOYMENTS; link.productionBranch matches EXPECTED_PRODUCTION_BRANCH (when configured); the latest production deployment is fresher than SLI_MAX_PRODUCTION_AGE_HOURS; and project.targets.production points at the newest READY production deployment (alias-current / no rollback in progress). Pushes five sub-metrics from one API call.

- **Robot task name**: <code>Score Vercel Deployment Health Signals</code>
- **Sub-metric name**: `production_deployment_ready`
- **Underlying script**: `sli-vercel-deployment-health-score.sh`
- **Tags**: `Vercel`, `sli`, `access:read-only`, `data:metrics`
- **Reads**: `EXPECTED_PRODUCTION_BRANCH`, `SLI_MAX_PRODUCTION_AGE_HOURS`, `SLI_MAX_RECENT_FAILED_DEPLOYMENTS`, `VERCEL_PROJECT_ID`


#### Score Vercel Domain Verification

Binary score: 1 when every production-bound domain attached to the project is verified, 0 if any production domain has verified=false. Calls GET /v9/projects/{id}/domains once per SLI run. Branch-bound preview aliases and custom-environment domains are excluded.

- **Robot task name**: <code>Score Vercel Domain Verification</code>
- **Sub-metric name**: `domains_verified_ok`
- **Tags**: `Vercel`, `sli`, `access:read-only`, `data:metrics`
- **Reads**: `VERCEL_PROJECT_ID`
- **Pass condition**: `(${total} == 0 or len(${unverified}) == 0)`


#### Score Vercel Runtime Error Sample

Binary score: 1 when error-class (status >= 400) rows in a capped sample of the historical request-logs endpoint stay at or below SLI_MAX_ERROR_EVENTS, 0 otherwise. Backed by GET https://vercel.com/api/logs/request-logs (the same endpoint the dashboard's Logs page uses) — NOT the live-tail /v1/runtime-logs endpoint.

- **Robot task name**: <code>Score Vercel Runtime Error Sample</code>
- **Sub-metric name**: `runtime_error_sample`
- **Tags**: `Vercel`, `sli`, `access:read-only`, `data:metrics`
- **Reads**: `SLI_LOOKBACK_HOURS`, `SLI_MAX_ERROR_EVENTS`, `SLI_MAX_ROWS`, `VERCEL_PROJECT_ID`, `VERCEL_REQUEST_LOGS_ENV`
- **Pass condition**: `${count} <= ${threshold}`


## Inputs

| Name | Type | Description | Default | Required |
|---|---|---|---|---|
| `VERCEL_TEAM_ID` | string | Vercel team slug or ID; leave empty for hobby projects scoped to the token owner | `` | yes |
| `VERCEL_PROJECT_ID` | string | Single Vercel project ID (prj_...); ignored when VERCEL_PROJECT_IDS is non-empty | `` | yes |
| `VERCEL_PROJECT_IDS` | string | Optional comma-separated project IDs for multi-project runs (overrides single ID when set) | `` | yes |
| `VERCEL_ARTIFACT_ROOT` | string | Parent directory for per-project JSON outputs when multiple projects are configured | `.vercel-health-projects` | no |
| `TIME_WINDOW_HOURS` | string | Lookback hours for log aggregation | `24` | no |
| `DEPLOYMENT_ENVIRONMENT` | string | production, preview, or all deployments when resolving IDs | `production` | no |
| `UNHEALTHY_HTTP_CODES` | string | Comma-separated extra HTTP status codes for the other-errors task | `408,429` | no |
| `MIN_REQUEST_COUNT_THRESHOLD` | string | Minimum requests per path before treating counts as high-severity in the summary | `5` | no |
| `VERCEL_REQUEST_LOGS_ENV` | string | Filter passed to the historical request-logs endpoint. Use 'production' (default) to score only what real users hit, 'preview' for branch deployments, or 'all' to combine. | `production` | no |
| `VERCEL_REQUEST_LOGS_MAX_ROWS` | string | Cap on rows fetched from the historical request-logs endpoint per project per run. Stops paginating once reached. | `5000` | no |
| `VERCEL_REQUEST_LOGS_MAX_PAGES` | string | Hard cap on pages walked even when hasMoreRows=true; bounds wall-clock for very busy projects. | `20` | no |
| `VERCEL_PROBE_PATHS` | string | Comma-separated paths to synthetic-probe against the production URL. Empty disables the probe task. | `/` | no |
| `VERCEL_PROBE_BASE_URL` | string | Optional explicit base URL for the synthetic probe; auto-resolved from the latest READY production deployment when empty. | `` | yes |
| `VERCEL_PROBE_TIMEOUT_SECONDS` | string | Per-request timeout for the synthetic probe (seconds). | `10` | no |
| `VERCEL_PROBE_SLOW_MS` | string | Probe latency threshold in ms; requests slower than this raise an informational issue. | `2000` | no |
| `DEPLOYMENT_SNAPSHOT_LIMIT` | string | Maximum deployments to include in the branch/status snapshot (most recent first) | `25` | no |
| `MAX_FAILED_DEPLOYMENTS_TO_DIAGNOSE` | string | Maximum recent ERROR/CANCELED deployments to enrich with build-error reason via GET /v13/deployments/{id}. Each adds one API call, so keep this small. | `2` | no |
| `MAX_DEPLOYMENTS_TO_SCAN` | string | Maximum READY deployments to keep when resolving the lookback window for log scans. | `10` | no |
| `SLI_LOOKBACK_HOURS` | string | Lookback window (hours) for the error-sample SLI. Defaults to TIME_WINDOW_HOURS when unset. | `24` | no |
| `SLI_MAX_ROWS` | string | Cap on rows fetched from the request-logs endpoint per SLI run. Bounds wall-clock for very busy projects. | `200` | no |
| `SLI_MAX_ERROR_EVENTS` | string | Maximum allowed HTTP 4xx/5xx events in the request-logs sample before the runtime_error_sample sub-score drops to 0. | `25` | no |
| `SLI_MAX_RECENT_FAILED_DEPLOYMENTS` | string | Allowed ERROR/CANCELED deployments in project.latestDeployments before the recent-failures SLI scores 0 | `1` | no |
| `SLI_MAX_PRODUCTION_AGE_HOURS` | string | Maximum hours since the latest production deployment before the production_deployment_fresh sub-score drops to 0 (default 168h / 7 days). Catches projects whose main branch has drifted far ahead of what is actually live. | `168` | no |
| `EXPECTED_PRODUCTION_BRANCH` | string | Optional expected production branch; when set, the production-branch SLI scores 0 if Vercel's link.productionBranch differs. Leave blank to skip the check. | `` | yes |

## Secrets

| Name | Description | Required |
|---|---|---|
| `vercel_token` | Vercel API bearer token with read access to project and deployment logs | yes |

## Outputs

- Monitor health score (`0.0`–`1.0`) pushed by `sli.robot`

## How to invoke

### Production (RunWhen runner / worker)

The platform **runner** schedules work on a location **worker**. The worker
image (`rw-base-runtime`) executes Robot via `runrobot.sh` with
`RW_PATH_TO_ROBOT` set to the bound path under `/home/runwhen/collection/`.

- **Runbook**: `codebundles/vercel-project-health/runbook.robot`
- **Monitor**: `codebundles/vercel-project-health/sli.robot`

### Local development (devcontainer only)

`ro` is a dev-time wrapper in `codecollection-devtools` — not the enterprise runtime.

```bash
cd codebundles/vercel-project-health
export VERCEL_TEAM_ID=...
export VERCEL_PROJECT_ID=...
export VERCEL_PROJECT_IDS=...
export VERCEL_ARTIFACT_ROOT=...
export TIME_WINDOW_HOURS=...
ro runbook.robot
```

### Standalone scripts (no Robot)


Set the input variables above, then run the matching script:

```bash
cd codebundles/vercel-project-health
export VERCEL_TEAM_ID=...
export VERCEL_PROJECT_ID=...
export VERCEL_PROJECT_IDS=...
bash aggregate-vercel-4xx-paths.sh
bash aggregate-vercel-5xx-paths.sh
bash aggregate-vercel-other-error-paths.sh
bash collect-vercel-request-logs.sh
bash diagnose-recent-failed-deployments.sh
bash probe-vercel-production-urls.sh
bash report-vercel-deployment-branches.sh
bash report-vercel-http-error-summary.sh
bash report-vercel-project-config.sh
bash report-vercel-project-domains.sh
bash resolve-vercel-deployments-in-window.sh
bash sli-vercel-deployment-health-score.sh
# ... and 1 more scripts
```

## Source files

- `runbook.robot` — orchestrates tools and raises issues
- `sli.robot` — monitor scoring (`sli.robot` runtime file)
- `aggregate-vercel-4xx-paths.sh` — Bash helper script `aggregate-vercel-4xx-paths.sh`.
- `aggregate-vercel-5xx-paths.sh` — Bash helper script `aggregate-vercel-5xx-paths.sh`.
- `aggregate-vercel-other-error-paths.sh` — Bash helper script `aggregate-vercel-other-error-paths.sh`.
- `collect-vercel-request-logs.sh` — Bash helper script `collect-vercel-request-logs.sh`.
- `diagnose-recent-failed-deployments.sh` — Bash helper script `diagnose-recent-failed-deployments.sh`.
- `probe-vercel-production-urls.sh` — Bash helper script `probe-vercel-production-urls.sh`.
- `report-vercel-deployment-branches.sh` — Bash helper script `report-vercel-deployment-branches.sh`.
- `report-vercel-http-error-summary.sh` — Bash helper script `report-vercel-http-error-summary.sh`.
- `report-vercel-project-config.sh` — Bash helper script `report-vercel-project-config.sh`.
- `report-vercel-project-domains.sh` — Bash helper script `report-vercel-project-domains.sh`.
- `resolve-vercel-deployments-in-window.sh` — Bash helper script `resolve-vercel-deployments-in-window.sh`.
- `sli-vercel-deployment-health-score.sh` — Bash helper script `sli-vercel-deployment-health-score.sh`.
- `vercel-helpers.sh` — Bash helper script `vercel-helpers.sh`.
