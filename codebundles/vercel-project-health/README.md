# Vercel Project Health

This CodeBundle inspects a Vercel project end-to-end: **project configuration** (sanitized), **recent deployments with git branches** and production readiness hints, **failed-deployment diagnostics** (real build error reasons), **production domain verification**, **historical HTTP traffic** (4xx, 5xx, optional codes) by route over a lookback window, and a complementary **synthetic HTTP probe** of production paths.

## Overview

- **Project configuration**: Fetches `GET /v9/projects/{id}` and writes `vercel_project_config.json` with safe fields only (environment variable **keys** listed, not values). Also caches the project's `accountId` (the `ownerId` the request-logs endpoint requires).
- **Deployment branch snapshot**: Lists recent deployments across production and preview, with `gitBranch`, commit SHA, READY state, and summary fields such as latest production deployment.
- **Failed deployment diagnostics**: For each `ERROR` / `CANCELED` entry in the snapshot (capped by `MAX_FAILED_DEPLOYMENTS_TO_DIAGNOSE`), pulls `GET /v13/deployments/{id}` and surfaces the actual `errorCode` + `errorMessage` + branch + commit, so on-call sees the real failure reason instead of just a count.
- **Production domain verification**: Lists every domain attached to the project (`GET /v9/projects/{id}/domains`), separates production-bound hostnames from preview/custom-environment aliases, and raises one issue per unverified production domain (with the TXT/CNAME records the user needs to add).
- **Deployment resolution (informational)**: Lists READY deployments whose active interval overlaps the lookback window. The historical-logs collector does **not** depend on this — the request-logs endpoint takes a time range directly — but the snapshot is still useful for correlating an error spike with a specific commit/deployment.
- **Historical request-log collection (single call)**: Hits Vercel's dashboard-backing request-logs endpoint once for the entire lookback window, paginates, and writes a shared `vercel_request_log_rows.json`. The bucket aggregators read this file instead of issuing more API calls. Filtered to `VERCEL_REQUEST_LOGS_ENV` (default `production`) so we score what real users hit.
- **4xx / 5xx / other codes**: Group the collected rows by `(code, path, method)`. The 4xx task covers **all** `400-499` responses (401/403/404/422/…) so it lines up with how the SLI counts errors.
- **Summary report**: Merges buckets, applies `MIN_REQUEST_COUNT_THRESHOLD`, emits JSON plus a top-routes table.
- **Synthetic HTTP probe**: Issues real GET requests against `VERCEL_PROBE_PATHS` on the latest production URL. Catches what historical logs cannot show on idle projects (DNS / cert / cold-start failures, regional CDN issues) and complements the log-based aggregations.
- **SLI**: **Eight** binary sub-scores averaged into a single project-health number — API reachability, latest production deployment is READY, recent deployment failure ratio is OK, production branch matches expectation (when configured), latest production deployment is fresh (≤ `SLI_MAX_PRODUCTION_AGE_HOURS`), production alias points at the newest READY deployment (no rollback in progress), every production domain is verified, and a capped runtime HTTP error sample.

## Configuration

### Project selection (use one approach)

- **`VERCEL_PROJECT_ID`**: Single **project id** (`prj_...`) or **slug/name** (resolved via `GET /v9/projects`). Artifacts are written to the task working directory unless multi-project layout applies.
- **`VERCEL_PROJECT_IDS`**: Comma-separated list of **ids or slugs** (optional spaces after commas). When set and non-empty, this **takes precedence** over `VERCEL_PROJECT_ID`, and the runbook executes every task once per ID.
- **Multiple projects**: When two or more IDs are configured, JSON outputs are written under **`VERCEL_ARTIFACT_ROOT/<project_id>/`** (default root `.vercel-health-projects`) so files do not overwrite each other.

**Project id vs slug:** You may set `VERCEL_PROJECT_ID` to either the **project id** (`prj_...`) or the **project name/slug**. Slugs are resolved with **`GET /v9/projects/{name}`** first (same as the project-config task), then by listing **`GET /v9/projects`** if needed. If the API returns **`invalidToken: true`**, the token is rejected by Vercel — create a new token at [vercel.com/account/tokens](https://vercel.com/account/tokens) and update your secret. Team-owned projects still need the correct **`VERCEL_TEAM_ID`**. Later tasks reuse **`vercel_project_config.json`** under `VERCEL_ARTIFACT_DIR` when it contains a `prj_` id (and `accountId` for the `ownerId` parameter).

### Optional variables

- `VERCEL_TEAM_ID`: Team slug or ID; leave unset for hobby projects scoped to the token owner.
- `VERCEL_ARTIFACT_ROOT`: Parent folder for per-project outputs when multiple projects are configured (default: `.vercel-health-projects`; ignored for artifact paths when only one project is configured).
- `TIME_WINDOW_HOURS`: Lookback hours for log aggregation (default: `24`). Vercel retains historical request logs for **roughly the last 3 days** — querying further back returns empty results. Use a Log Drain (https://vercel.com/docs/log-drains) to ship logs to your own backend if you need longer retention.
- `DEPLOYMENT_ENVIRONMENT`: `production`, `preview`, or `all` for the **deployment listing tasks** (default: `production`). Independent of the request-logs filter below.
- `VERCEL_REQUEST_LOGS_ENV`: Filter passed directly to the request-logs endpoint (`production` / `preview` / `all`, default `production`). Scoping to production keeps the SLI focused on real-user traffic and excludes branch deployments.
- `VERCEL_REQUEST_LOGS_MAX_ROWS`: Cap on rows fetched per project per run (default: `5000`). Stops paginating once reached.
- `VERCEL_REQUEST_LOGS_MAX_PAGES`: Hard cap on pages walked (default: `20`). Bounds wall-clock for very busy projects even when `hasMoreRows=true`.
- `DEPLOYMENT_SNAPSHOT_LIMIT`: Max deployments in the branch/status snapshot task (default: `25`).
- `MAX_FAILED_DEPLOYMENTS_TO_DIAGNOSE`: Max recent ERROR/CANCELED deployments to enrich with build-error reason via `GET /v13/deployments/{id}` (default: `2`). Each adds one API call, so keep it small.
- `UNHEALTHY_HTTP_CODES`: Comma-separated extra codes for the other-errors task (default: `408,429`).
- `MIN_REQUEST_COUNT_THRESHOLD`: Minimum requests per path before treating volume as high-severity in the summary (default: `5`).

### Synthetic probe variables

- `VERCEL_PROBE_PATHS`: Comma-separated paths to probe against the production URL (default: `/`). Set to an empty string to skip probe execution.
- `VERCEL_PROBE_BASE_URL`: Optional explicit base URL; auto-resolves from the latest READY production deployment when empty.
- `VERCEL_PROBE_TIMEOUT_SECONDS`: Per-request timeout (default: `10`).
- `VERCEL_PROBE_SLOW_MS`: Latency threshold; OK responses slower than this raise an informational issue (default: `2000`).

### SLI-only optional variables

The SLI (`sli.robot`) evaluates **one** project per indicator (`VERCEL_PROJECT_IDS` is not used there). The deployment-health SLI emits **five** sub-scores from a single `GET /v9/projects/{id}` call. The domains SLI adds **one** call (`GET /v9/projects/{id}/domains`). The error-sample SLI adds **one** small request-logs call (status >= 400 only, capped at `SLI_MAX_ROWS`). Total per SLI run: 3 Vercel API calls regardless of project size.

- `SLI_LOOKBACK_HOURS`: Lookback window for the error-sample SLI (default: `24`).
- `SLI_MAX_ROWS`: Cap on rows fetched from the request-logs endpoint per SLI run (default: `200`).
- `SLI_MAX_ERROR_EVENTS`: Max HTTP 4xx/5xx events allowed in that sample before the SLI scores 0 (default: `25`).
- `SLI_MAX_RECENT_FAILED_DEPLOYMENTS`: Allowed `ERROR`/`CANCELED` deployments in `project.latestDeployments` before the recent-failures SLI scores 0 (default: `1`).
- `SLI_MAX_PRODUCTION_AGE_HOURS`: Maximum hours since the latest production deployment before `production_deployment_fresh` drops to 0 (default: `168`, i.e. 7 days). Useful for catching projects whose `main` branch has drifted far ahead of what's actually live.
- `EXPECTED_PRODUCTION_BRANCH`: Optional expected production branch. When set, the production-branch SLI scores 0 if Vercel's `link.productionBranch` differs. Leave blank to skip the check (the sub-score then always scores 1).

### Secrets

- `vercel_token`: Vercel API bearer token (`VERCEL_TOKEN`) with read access to the project. The same token works for both `api.vercel.com` REST calls and the dashboard-backing request-logs endpoint.

## Tasks overview

### Fetch Vercel Project Configuration

Loads project metadata into `vercel_project_config.json` (under `VERCEL_ARTIFACT_DIR`). Caches `accountId` for the request-logs collector. Raises an issue if the API call fails.

### Report Vercel Deployment Branches and Status

Writes `vercel_deployments_snapshot.json` with recent deployments (production and preview), git metadata, and summary hints. May raise issues when no deployments exist or the latest production deployment is not READY.

### Diagnose Recent Failed Vercel Deployments

Reads `vercel_deployments_snapshot.json`, picks the newest `ERROR` / `CANCELED` deployments (capped by `MAX_FAILED_DEPLOYMENTS_TO_DIAGNOSE`, default `2`), and for each one calls `GET /v13/deployments/{id}` to extract the actual `errorCode`, `errorMessage`, build duration, branch, commit SHA, and commit message. Writes `vercel_failed_deployment_diagnoses.json` and emits one issue per surfaced failure with a deep link to the Vercel dashboard build log. Cost: at most `MAX_FAILED_DEPLOYMENTS_TO_DIAGNOSE` API calls per run, and zero when no failures exist.

### Verify Vercel Project Production Domains

Calls `GET /v9/projects/{id}/domains`, separates production-bound hostnames (no `gitBranch`, no `customEnvironmentId`) from preview/custom-environment aliases, reports verification + redirect state, and raises one issue per **unverified** production domain. Each issue includes the TXT/CNAME records the user needs to add at their DNS provider — turning "site not loading on the custom domain" into an immediately actionable ticket. Writes `vercel_project_domains.json`.

### Resolve Vercel Deployments in Time Window

Lists overlapping deployments and writes `vercel_deployments_context.json`. Informational only — the historical-log collector does not depend on this output. Useful for correlating a spike to a specific commit/deployment.

### Collect Vercel Request Logs

Hits `GET https://vercel.com/api/logs/request-logs?projectId=...&ownerId=...&startDate=<ms>&endDate=<ms>&page=N` once for the lookback window, paginates until `hasMoreRows=false` (or the configured row/page caps), and writes `vercel_request_log_rows.json` plus a debug summary. Subsequent aggregate tasks are pure `jq` filters over this file — they do **not** call Vercel again. Raises an issue if the endpoint fails or the project's `accountId` cannot be resolved.

> **About this endpoint:** It is the same endpoint the Vercel dashboard's "Logs" page and the `vercel logs` CLI v2 use. It supports time-range queries (unlike the public `/v1/runtime-logs` endpoint, which is **live-tail only**) and server-side filtering by `environment`, `statusCode`, `source`, `deploymentId`, and `branch`. **It is not in the public REST API reference.** Vercel ships the official CLI on `main` against this endpoint, but it is technically undocumented and could change without notice. If a bundle run starts returning empty rows or 4xx errors against the endpoint, run `/tmp/validate-vercel-request-logs.sh` (or the smoke test at `/tmp/smoke-vercel-request-logs-cli.sh`) to confirm the endpoint shape, and check the Vercel CLI source (`logs-v2.ts`) for any changes. For longer retention than the ~3-day window, configure a [Log Drain](https://vercel.com/docs/log-drains) to ship logs to your own backend.

### Aggregate 4xx / 5xx / Other Unhealthy HTTP Codes

Three lightweight tasks (`timeout_seconds=60` each — they only `jq` the shared rows file). The 4xx task covers all `400-499` responses; the 5xx task covers `500-599`; the "other" task covers the codes listed in `UNHEALTHY_HTTP_CODES` (default `408,429`). Each writes a per-bucket JSON under `vercel_aggregate_{4xx,5xx,other}.json` grouped by `(code, path, method)` with sample timestamps, unique domains, sources and levels.

### Build Consolidated Vercel HTTP Error Summary

Merges aggregates into `vercel_http_error_summary.json` and opens issues when unhealthy route volume exceeds thresholds. Bucket totals are reported as `4xx`, `5xx`, `other`. The "rows scanned" count comes from the single collector pass, not the per-bucket scripts.

### Probe Production URL Paths

Fires real `curl` GETs against each path in `VERCEL_PROBE_PATHS` on the production URL (auto-resolved from the latest READY deployment, or overridden via `VERCEL_PROBE_BASE_URL`). Aggregates by status code + latency and raises issues for 4xx / 5xx / outright failures / latency above `VERCEL_PROBE_SLOW_MS`. **Complementary to the log-based aggregations**: it catches DNS / cert / cold-start / regional CDN failures that the historical logs cannot show on idle projects, and it works even when the request-logs endpoint is empty.

## SLI signals

`sli.robot` averages **eight** binary sub-scores into the primary `vercel_health` metric. All eight are pushed individually as Push Metric `sub_name` values so dashboards can split them out.

| Sub-metric | Source | Score 0 means |
| --- | --- | --- |
| `vercel_api_ok` | `GET /v9/projects/{id}` returns 200 | Token rejected, project missing, or Vercel unreachable |
| `production_deployment_ready` | `project.latestDeployments` newest production entry | Latest production build is `BUILDING` / `ERROR` / `CANCELED` / `QUEUED` |
| `recent_deployment_failures_ok` | Count of `ERROR` + `CANCELED` in `project.latestDeployments` | More than `SLI_MAX_RECENT_FAILED_DEPLOYMENTS` recent failures |
| `production_branch_matches` | `project.link.productionBranch` vs `EXPECTED_PRODUCTION_BRANCH` | The configured branch differs from what Vercel is using |
| `production_deployment_fresh` | Age of the latest production deployment | Latest production deploy is older than `SLI_MAX_PRODUCTION_AGE_HOURS` (default 168h / 7 days) |
| `production_alias_current` | `project.targets.production.id` vs newest READY production deployment | Production alias points at an older deployment than the newest READY one (rollback in progress, or the latest deploy hasn't aliased yet) |
| `domains_verified_ok` | `GET /v9/projects/{id}/domains` (production-bound only) | At least one production domain has `verified=false` |
| `runtime_error_sample` | One small page from `vercel.com/api/logs/request-logs?statusCode=400` | More than `SLI_MAX_ERROR_EVENTS` error-class rows in the sample window |

API cost: **3 calls per SLI run, total** — `GET /v9/projects/{id}` (covers sub-scores 1-6), `GET /v9/projects/{id}/domains` (sub-score 7), and one page of `vercel.com/api/logs/request-logs` (sub-score 8). Independent of project size.

## Shared library

Vercel REST helpers live in **`codecollection/libraries/Vercel/`** as a Python keyword library — importable from Robot via `Library    Vercel` and callable from bash via `python -m Vercel <subcommand>`. This bundle uses both surfaces: `runbook.robot`/`sli.robot` shell out to bash scripts (per the existing convention), and those scripts invoke the CLI through the local `vercel-helpers.sh::vercel_py` wrapper which resolves `PYTHONPATH` from the dev tree (`codecollection/libraries`) or the runner image (`/home/runwhen/codecollection/libraries`). New Vercel codebundles should reuse this library instead of duplicating REST logic.

`vercel-helpers.sh` (in this bundle) holds bundle-private bash glue only — artifact directory layout, lookback-window math, jq aggregation filters, and issue-text formatters — not API logic.

## API notes

Uses the Vercel REST API via the shared `Vercel` Python library (HTTP/1.1, `Connection: close`, `Accept-Encoding: identity`, `urllib3.Retry` for transient 5xx and connection resets):

- **List deployments** — [`GET /v6/deployments`](https://vercel.com/docs/rest-api/reference/endpoints/deployments/list-deployments) with `projectId`, `teamId`, optional `target`.
- **Project metadata / slug resolve** — [`GET /v9/projects/{idOrName}`](https://vercel.com/docs/rest-api/reference/endpoints/projects/find-a-project-by-id-or-name).
- **Project domains** — [`GET /v9/projects/{idOrName}/domains`](https://vercel.com/docs/rest-api/reference/endpoints/projects/get-a-project-domain). Used by the domain verification task and SLI.
- **Single deployment** — [`GET /v13/deployments/{idOrUrl}`](https://vercel.com/docs/rest-api/reference/endpoints/deployments/get-a-deployment-by-id-or-url). Used by the failed-deployment diagnostics task to pull the real `errorCode` + `errorMessage`.
- **Historical request logs (undocumented)** — `GET https://vercel.com/api/logs/request-logs?projectId=...&ownerId=...&page=N&startDate=<ms>&endDate=<ms>` plus optional `environment`, `statusCode`, `source`, `level`, `deploymentId`, `branch`. The Vercel dashboard's "Logs" page and `vercel logs` v2 use this endpoint. Returns `{rows: [...], hasMoreRows: bool}`. Same Bearer-token auth as `api.vercel.com`. Hosted on `vercel.com` (note: not `api.vercel.com`). Retention is ~3 days; pipe to a [Log Drain](https://vercel.com/docs/log-drains) for longer.

Vercel's REST API uses per-resource version prefixes that have evolved independently — `v6`, `v9`, and `v13` are all current for these operations. There is no single base version. Tunables for the deployments listing path: `VERCEL_PAGE_MAX_TIME`, `VERCEL_PAGE_RETRY_ATTEMPTS`, `VERCEL_DEPLOYMENTS_PAGE_LIMIT`, `VERCEL_DEPLOYMENTS_MAX_PAGES` (defaults: 90s timeout, 4 retries, 50 deployments/page, 20 pages). Tunables for the request-logs path: `VERCEL_REQUEST_LOGS_MAX_ROWS`, `VERCEL_REQUEST_LOGS_MAX_PAGES`, `VERCEL_REQUEST_LOGS_TIMEOUT` (defaults: 5000 rows, 20 pages, 30s).

The published [`/v1/projects/{projectId}/deployments/{deploymentId}/runtime-logs`](https://vercel.com/docs/rest-api/reference/endpoints/logs/get-logs-for-a-deployment) endpoint is **live-tail only** — it streams new events as they arrive and never returns historical data. The `request_logs()` method in `vercel.py` exists for live-tail use cases (e.g., kicking off a stream and watching for new errors during a deployment) but is no longer used by the runbook tasks since it cannot serve a "what happened in the last N hours" query.

## Generation

Generation rules match workspace resources of type `vercel_project`. Template `configProvided` expects resource metadata fields `team_id` and `project_id` (or adjust templates to your workspace schema). This bundle was renamed from `vercel-project-http-errors`; update `pathToRobot` and generation `baseName` to `vercel-project-health` if you referenced the old path.
