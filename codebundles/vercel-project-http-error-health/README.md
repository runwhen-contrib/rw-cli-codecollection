# Vercel Project HTTP Error Health

This CodeBundle monitors frontend and edge/serverless request health on Vercel by sampling **runtime logs** for the latest **production** deployment. It reports 4xx and 5xx rates against configurable thresholds, optional 404 handling for 4xx analysis, and the top request paths driving failures.

## Overview

- **Access validation**: Confirms the API token can read the team scope and resolves the project by id or slug.
- **Deployment selection**: Uses the latest `READY` deployment with `target=production` as the log source (documented in the resolve task output).
- **Error rates**: Computes 5xx and (optionally non-404) 4xx rates from sampled request rows in `LOOKBACK_MINUTES`, compared to `ERROR_RATE_THRESHOLD_PCT` and `MIN_ERROR_EVENTS`.
- **Top paths**: Lists the most frequent failing paths for 5xx and for 4xx (with optional 404 exclusion).

Runtime logs are retrieved via `GET /v1/projects/{projectId}/deployments/{deploymentId}/runtime-logs` (NDJSON). High-volume traffic may be **sampled** by line limits; rates are approximate and documented in task output.

## Configuration

### Required Variables

- `VERCEL_TEAM_ID`: Vercel team id (`teamId` query parameter for API calls).
- `VERCEL_PROJECT`: Project id or slug to analyze.

### Optional Variables

- `LOOKBACK_MINUTES`: Log window ending at now (default: `60`).
- `ERROR_RATE_THRESHOLD_PCT`: Percent of sampled request rows that may be errors before raising a rate issue (default: `1`).
- `MIN_ERROR_EVENTS`: Minimum error count before treating a high rate as a high-severity signal (default: `5`).
- `EXCLUDE_404_FROM_4XX`: If `true`, HTTP 404 is excluded from 4xx summaries and top-path lists (default: `true`).

### Secrets

- `vercel_api_token`: Vercel bearer token with permission to read projects and deployment runtime logs (personal or team token).

## Tasks Overview

### Validate Vercel API Access and Resolve Project

Calls `GET /v9/projects/{idOrName}` to verify credentials and resolve the project. Raises issues on HTTP 401/403/404 or other API failures.

### Resolve Production Deployment for Log Analysis

Lists production deployments and picks the newest `READY` deployment. Raises an issue if none are available (for example preview-only projects).

### Summarize 5xx Server Error Rate

Counts HTTP 500–599 responses in sampled logs and compares the rate to `ERROR_RATE_THRESHOLD_PCT` and `MIN_ERROR_EVENTS`.

### Summarize 4xx Client Error Rate (incl. 400)

Counts HTTP 400–499 responses, optionally excluding 404 when `EXCLUDE_404_FROM_4XX` is true, using the same rate thresholds.

### List Top Error Paths by 5xx Count

Prints a ranked list of paths by 5xx volume for the lookback window (informational; issues only on resolution failures).

### List Top Paths by 4xx (non-404) Count

Same for 4xx, respecting `EXCLUDE_404_FROM_4XX`.
