# Vercel Project Path Traffic and Missing Routes

This CodeBundle reads Vercel **runtime request logs** for a production deployment and summarizes what users hit most often (2xx/optional 3xx), which paths return the most 404s, whether the share of 404s exceeds a threshold, and a first-segment path rollup. It complements synthetic checks by using real request data. Very high traffic may require tighter `LOG_SAMPLE_MAX_LINES` / shorter `LOG_FETCH_MAX_SECONDS`; edge-cached static responses may be under-represented compared to CDN or analytics.

## Overview

- **Access validation**: Confirms the token can read the team-scoped project.
- **Deployment selection**: Uses the latest READY **production** deployment for log streaming.
- **Popular paths**: Ranks paths by successful responses in the lookback window.
- **Top 404 paths**: Surfaces the most frequent missing routes.
- **404 spike detection**: Flags when 404s exceed a configured share of sampled requests (minimum sample size required).
- **Prefix summary**: Aggregates total requests and 404 counts by first URL segment (for example `/blog`, `/docs`).
- **SLI**: Lightweight periodic score (0 to 1) from project access, deployment presence, and sampled 404 share.

## Configuration

### Required variables

- `VERCEL_TEAM_ID`: Vercel team id (`teamId`) used on API calls.
- `VERCEL_PROJECT`: Project id or slug to analyze.

### Optional variables

- `LOOKBACK_MINUTES`: Log aggregation window in minutes (default: `60`).
- `TOP_N_PATHS`: Number of rows in ranked lists (default: `25`).
- `NOT_FOUND_SPIKE_THRESHOLD_PCT`: Issue when sampled 404 share exceeds this percent (default: `15`).
- `INCLUDE_3XX`: Include redirects in “popular paths” when `true` (default: `true`).
- `SPIKE_MIN_SAMPLE`: Minimum sampled requests with status before evaluating the spike threshold (default: `40`).
- `LOG_SAMPLE_MAX_LINES`: Max streamed log lines processed per runbook task (default: `50000`).
- `LOG_FETCH_MAX_SECONDS`: Max time to read the runtime log stream per task (default: `90`).

The SLI uses the same variables where applicable; defaults for `LOG_SAMPLE_MAX_LINES` and `LOG_FETCH_MAX_SECONDS` in `sli.robot` are smaller (`3000` / `20`) so the check stays within about 30 seconds.

### Secrets

- `vercel_api_token`: Vercel bearer token with read access to projects and deployment runtime logs (plain text).

## Tasks overview

### Validate Vercel API Access and Resolve Project

Checks the token and resolves the project record; raises issues on auth or resolution failures.

### Resolve Production Deployment for Log Analysis

Selects the latest READY production deployment used when querying runtime logs.

### Rank Top Popular Paths by Successful Responses

Lists the most common paths for 2xx responses (and 3xx when enabled) within the lookback window.

### Rank Top Missing Paths by 404 Count

Lists paths with the highest 404 frequency in the sampled logs.

### Detect Abnormal 404 Spike

Opens an issue when the 404 share of sampled requests exceeds `NOT_FOUND_SPIKE_THRESHOLD_PCT` and the sample size is at least `SPIKE_MIN_SAMPLE`.

### Optional Path Prefix Summary

Rolls up request totals and 404 counts by the first path segment to spot section-level trends.
