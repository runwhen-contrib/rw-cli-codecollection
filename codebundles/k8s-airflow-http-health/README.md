# Kubernetes Airflow HTTP/API Health

This CodeBundle checks Apache Airflow webserver availability using HTTP GET probes against the webserver `/health` endpoint and read-only REST routes, then correlates results with Kubernetes Service and Endpoints objects. Optional checks target scheduler or triggerer Services when those names are configured.

## Overview

- **Connectivity**: Resolves `PROXY_BASE_URL` or uses `kubectl port-forward` to the webserver Service
- **Webserver health**: Validates `/health` JSON (metadata DB, scheduler, and optional components when reported)
- **REST API**: Probes `/api/v1/health`, `/api/v2/monitor/health`, or `/api/v1/version` with optional credentials
- **Kubernetes context**: Confirms the webserver Service exists, has Endpoints, and port alignment
- **Optional tiers**: When `AIRFLOW_SCHEDULER_SERVICE_NAME` or `AIRFLOW_TRIGGERER_SERVICE_NAME` is set, performs lightweight HTTP attempts (many charts do not expose HTTP here)

## Configuration

### Required variables

These are imported via `RW.Core.Import User Variable` in `runbook.robot`:

- `CONTEXT`: Kubernetes context name for `kubectl` and port-forward
- `NAMESPACE`: Namespace where Airflow runs
- `AIRFLOW_WEBSERVER_SERVICE_NAME`: Kubernetes Service name for the Airflow webserver

### Optional variables

- `PROXY_BASE_URL`: Full HTTP base URL for the web UI (for example `http://airflow-webserver.my-ns.svc.cluster.local:8080`). Leave empty to use automatic `kubectl port-forward` to the Service
- `AIRFLOW_HTTP_PORT`: Service port for the web UI/API (default: `8080`)
- `AIRFLOW_SCHEDULER_SERVICE_NAME`: Optional Service name for extra HTTP checks
- `AIRFLOW_TRIGGERER_SERVICE_NAME`: Optional Service name for Airflow 2 triggerer HTTP checks
- `KUBERNETES_DISTRIBUTION_BINARY`: `kubectl` or `oc` (default: `kubectl`)

### Secrets

- `kubeconfig`: Standard kubeconfig used for `kubectl` and optional port-forward
- `airflow_api_credentials`: Optional JSON for authenticated REST routes, for example `{"token":"..."}` or `{"username":"admin","password":"..."}`

## Tasks overview

### Resolve Airflow Webserver Base URL

Validates that either `PROXY_BASE_URL` responds on `GET /health` or that port-forward to `AIRFLOW_WEBSERVER_SERVICE_NAME` works. Surfaces connectivity and early misconfiguration issues.

### Check Airflow Webserver Health Endpoint

Calls `GET /health` and inspects JSON status fields (for example `metadatabase`, `scheduler`) when present, flagging unhealthy or missing states.

### Check Airflow REST API Health or Version

Tries read-only API paths in order (version-dependent across Airflow 2.x and newer). Uses `airflow_api_credentials` when the API rejects anonymous access.

### Verify Kubernetes Service and Endpoints for Webserver

Uses `kubectl` to confirm the Service exists, has ready Endpoints, and exposes the expected `AIRFLOW_HTTP_PORT`.

### Optional Check Scheduler or Triggerer HTTP Health

If optional Service names are set, checks endpoints and attempts HTTP on the first Service port or documents that no HTTP listener responded (common when charts do not expose HTTP on these tiers).

## SLI

`sli.robot` aggregates three binary dimensions (webserver `/health`, API reachability, Service existence) into a single 0–1 score for periodic monitoring.
