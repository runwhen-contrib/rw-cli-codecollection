# Kubernetes Application Log Health

This codebundle provides tasks for triaging application log health of Kubernetes workloads (deployments, statefulsets, or daemonsets). It fetches pod logs, scans for error patterns, and reports issues with severity and next steps.

## Tasks

**Runbook**
- `Analyze Application Log Patterns for ${WORKLOAD_TYPE} ${WORKLOAD_NAME} in Namespace ${NAMESPACE}` — Fetches workload logs, scans for configurable error/exception patterns, creates issues for matches above the severity threshold, and reports a log health score and summary.
- `Fetch Workload Logs for ${WORKLOAD_TYPE} ${WORKLOAD_NAME} in Namespace ${NAMESPACE}` — Fetches and attaches workload logs to the report for manual review (no issue creation).

**SLI**
- `Get Critical Log Errors and Score for ${WORKLOAD_TYPE} ${WORKLOAD_NAME}` — Fetches logs and scores health based on critical error patterns (e.g. GenericError, AppFailure) and container restarts; pushes a metric for SLI scoring.
- `Generate Application Health Score for ${WORKLOAD_TYPE} ${WORKLOAD_NAME}` — Computes the final applog health score and report details (e.g. scaled-to-zero vs healthy vs issues).

### Log pattern categories

Analysis uses pattern categories (configurable via `runbook_patterns.json` or `sli_critical_patterns.json`). Examples:

- **GenericError** — exception, fatal, panic, crash, failed, failure (severity 1)
- **AppFailure** — application failed, service unavailable, connection refused, timeout, OOM, disk full, auth failures (severity 1)
- **StackTrace** — stack trace, exception in thread, java.lang., traceback, panic (severity 1)
- **Connection** — connection reset/timeout, network unreachable, socket error, DNS resolution failed (severity 2)
- **Timeout** — request/operation timeout, deadline exceeded, read/write timeout (severity 2)
- **Auth** — unauthorized, authentication error, invalid credentials, forbidden, token expired (severity 2)
- **Exceptions** — NullPointerException, IllegalArgumentException, SQLException, IOException, etc. (severity 2)
- **Resource** — resource exhausted, memory leak, CPU throttled, quota/rate limit exceeded (severity 2)
- **HealthyRecovery** — recovered from error, connection restored, retry successful (severity 4, informational)

Exclude patterns (e.g. INFO/DEBUG/TRACE, health checks, heartbeats) reduce false positives.

## Configuration

The TaskSet/SLI requires initialization with secrets and user variables. Key variables:

- `kubeconfig` — Secret containing cluster access (kubeconfig YAML).
- `KUBERNETES_DISTRIBUTION_BINARY` — CLI binary for Kubernetes (`kubectl` or `oc`). Default: `kubectl`.
- `CONTEXT` — Kubernetes context to use.
- `NAMESPACE` — Namespace of the workload. Leave blank to search all namespaces.
- `WORKLOAD_NAME` — Name of the deployment, statefulset, or daemonset to analyze.
- `WORKLOAD_TYPE` — Type of workload: `deployment`, `statefulset`, or `daemonset`. Default: `deployment`.
- `LOG_AGE` — Age of logs to fetch (e.g. `10m`). Default: `10m`.
- `LOG_LINES` / `LOG_SIZE` — Max lines or bytes per container for runbook log fetch. Defaults: 1000 lines, 2MB.
- `LOG_SEVERITY_THRESHOLD` — Minimum severity to create issues (1=critical … 5=info). Default: 3.
- `LOG_PATTERN_CATEGORIES` — Comma-separated categories to scan (e.g. `GenericError,AppFailure,Connection`). Default includes GenericError, AppFailure, Connection, Timeout, Auth, Exceptions, Resource, HealthyRecovery.
- `LOGS_EXCLUDE_PATTERN` — Regex to exclude lines from analysis (e.g. INFO/DEBUG, health checks).
- `EXCLUDED_CONTAINER_NAMES` — Comma-separated container names to skip (e.g. `linkerd-proxy,istio-proxy`). Default: `linkerd-proxy,istio-proxy,vault-agent`.
- `CONTAINER_RESTART_AGE` / `CONTAINER_RESTART_THRESHOLD` — Time window and threshold for container restarts (SLI). Defaults: e.g. `10m`, `1`.
- `LOG_SCAN_TIMEOUT` — Timeout in seconds for log scanning. Default: 300.

## Requirements

- A kubeconfig with RBAC permissions to list pods and read logs for the target workload and namespace.

## TODO

- [ ] Add additional documentation.
