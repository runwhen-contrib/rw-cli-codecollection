# Vercel Project HTTP Error Routes and Logs

This CodeBundle reads Vercel deployment runtime logs over a configurable lookback window, aggregates HTTP 404s, 5xx responses, and optional additional error codes by route, and produces a consolidated summary for triage. It complements synthetic URL checks by using historical traffic seen on Vercel.

## Overview

- **Deployment resolution**: Finds READY deployments whose active interval overlaps the lookback window (production, preview, or all), capped by `MAX_DEPLOYMENTS_TO_SCAN`.
- **404 aggregation**: Counts 404 responses per path and method with sample timestamps from runtime logs.
- **5xx aggregation**: Same pipeline for server errors to separate application or edge failures from missing routes.
- **Other error codes**: Aggregates extra status codes from `UNHEALTHY_HTTP_CODES` (for example 408, 429).
- **Summary report**: Merges buckets, applies `MIN_REQUEST_COUNT_THRESHOLD` for severity, and emits JSON plus a TSV-style top-routes table.
- **SLI**: Lightweight checks for project API reachability and a capped runtime error sample (see SLI template variables).

## Configuration

### Required variables

- `VERCEL_PROJECT_ID`: Vercel project ID (`prj_...`).

### Optional variables

- `VERCEL_TEAM_ID`: Team slug or ID; leave unset for hobby projects scoped to the token owner.
- `TIME_WINDOW_HOURS`: Lookback hours for aggregation (default: `24`).
- `DEPLOYMENT_ENVIRONMENT`: `production`, `preview`, or `all` (default: `production`).
- `UNHEALTHY_HTTP_CODES`: Comma-separated extra codes for the other-errors task (default: `408,429`).
- `MIN_REQUEST_COUNT_THRESHOLD`: Minimum requests per path before treating volume as high-severity in the summary (default: `5`).
- `MAX_DEPLOYMENTS_TO_SCAN`: Maximum deployments to pull logs from per run (default: `10`).
- `RUNTIME_LOG_MAX_LINES_PER_DEPLOYMENT`: Cap on streamed log lines per deployment (default: `10000`).

### SLI-only optional variables

- `SLI_LOG_LINE_CAP`: Max log lines read for the SLI error sample (default: `800`).
- `SLI_MAX_ERROR_EVENTS`: Max HTTP 4xx/5xx lines allowed in that sample before the SLI scores 0 (default: `25`).

### Secrets

- `vercel_token`: Vercel API bearer token (`VERCEL_TOKEN`) with read access to the project and deployment runtime logs.

## Tasks overview

### Resolve Vercel Deployments in Time Window

Lists overlapping deployments and writes `vercel_deployments_context.json`. Raises an issue if the API call fails or no deployment covers the window.

### Aggregate 404 / 5xx / Other Unhealthy HTTP Codes

Scan runtime logs for each resolved deployment (via `GET /v1/projects/{projectId}/deployments/{deploymentId}/runtime-logs`), filter by status and time window, and write per-bucket JSON under `vercel_aggregate_*.json`.

### Build Consolidated Vercel HTTP Error Summary

Merges aggregates into `vercel_http_error_summary.json` and opens a single issue when any unhealthy route has traffic in the window, with severity driven by 5xx volume and the configured threshold.

## API notes

Implements the documented Vercel REST API using `curl` and `jq` only: deployment listing (`/v6/deployments`), project metadata (SLI: `/v9/projects/{id}`), and per-deployment runtime logs. Log responses are streamed JSON lines; scripts cap bytes/lines to stay within task timeouts. If Vercel changes field names for status, path, or timestamp, adjust `vercel-http-lib.sh` normalizers.

## Generation

Generation rules match workspace resources of type `vercel_project`. Template `configProvided` expects resource metadata fields `team_id` and `project_id` (or adjust templates to your workspace schema).
