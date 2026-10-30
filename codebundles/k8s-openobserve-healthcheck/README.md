# Kubernetes OpenObserve Health Check

This CodeBundle checks the overall health of an OpenObserve deployment running in Kubernetes: workload/pod health, API reachability, and - because storage cannot be inspected from inside the container - storage/ingestion/cluster state queried through the OpenObserve HTTP API using credentials resolved from Kubernetes secrets (with automatic port-forward to the Service).

## Overview

- **Resource discovery**: `kubectl` inventory of OpenObserve workloads, Services, PVCs, Secrets, and ConfigMaps in the namespace.
- **Workload health**: Deployment/StatefulSet ready vs desired replicas.
- **Pod health**: non-Running phases, CrashLoopBackOff, failed readiness, high restart counts.
- **API health**: OpenObserve HTTP health endpoint(s) via `HTTP Basic` auth, with automatic `kubectl port-forward` to the Service.
- **Storage metrics** (API): `storage_metrics` `s3_access_failures`, WAL/parquet growth, upload issues - the source of truth for storage, since storage is not observable from inside the container.
- **Cluster processing** (API): per-node pending compaction jobs via `cluster_info`.
- **Ingestion queue** (API): memory/disk queue key growth that signals ingestion backing up.
- **Storage configuration**: workload env audit of `ZO_LOCAL_MODE`, `ZO_DATA_DIR`, and `ZO_S3_*` settings.
- **PVC capacity**: bound status, capacity, and reclaim policy; never execs `df` or inspects storage from inside a container.
- **SLI**: `sli.robot` averages API reachability, replica readiness, and storage health into a 0-1 score.

OpenObserve defaults: port **5080** (HTTP API + web UI) and **5081** (grpc). All org-scoped API endpoints use HTTP Basic auth (`Authorization: Basic base64("username:password")`).

## Configuration

### Required variables

- `CONTEXT`: Kubernetes context for kubectl-backed tasks and the automatic port-forward.
- `NAMESPACE`: Namespace where OpenObserve runs.
- `OBJECT_NAME`: OpenObserve workload name (Deployment or StatefulSet) this SLX monitors; used to scope Pod and credential discovery.

### Optional variables

- `KUBERNETES_DISTRIBUTION_BINARY`: `kubectl` or `oc` (default: `kubectl`).
- `OPENOBSERVE_SERVICE_NAME`: Service exposing the OpenObserve HTTP port. Auto-discovered from a Service whose name contains `openobserve` when empty.
- `OPENOBSERVE_HTTP_PORT`: OpenObserve HTTP port on the Service (default: `5080`).
- `OPENOBSERVE_LOCAL_PORT`: Local port used when auto port-forwarding (default: `5080`).
- `OPENOBSERVE_ORGANIZATION`: Organization used in API paths (`/api/{org}/...`) (default: `default`).
- `OPENOBSERVE_BASE_URL`: Optional direct Base URL (e.g. `http://openobserve.<ns>.svc.cluster.local:5080`). Leave empty to auto start `kubectl port-forward` to `svc/${OPENOBSERVE_SERVICE_NAME}` on `${OPENOBSERVE_HTTP_PORT}`.
- `OPENOBSERVE_API_TIMEOUT`: Timeout in seconds for API curl calls (default: `25`).
- `OPENOBSERVE_PF_WAIT_SECS`: Max seconds to wait for the automatic port-forward (default: `15`).
- `OPENOBSERVE_CREDENTIAL_SECRET_NAME`: Optional Kubernetes Secret name holding the OpenObserve credentials. When empty, infers from the workload Pod env (`ROOT_USER_EMAIL`/`ROOT_USER_PASSWORD` or `ZO_ROOT_USER_*`), following `secretKeyRef`.
- `OPENOBSERVE_CREDENTIAL_USER_KEY`: Secret data key for the API username; auto-probes `ROOT_USER_EMAIL`, `ZO_ROOT_USER_EMAIL`, `ROOT_USER_NAME` when empty.
- `OPENOBSERVE_CREDENTIAL_PASSWORD_KEY`: Secret data key for the API password; auto-probes `ROOT_USER_PASSWORD`, `ZO_ROOT_USER_PASSWORD` when empty.
- `OPENOBSERVE_ALLOW_EXEC`: Set to `true` to allow `kubectl exec <pod> -- printenv` as a last-resort credential fallback (default: `false`).
- `OPENOBSERVE_POD_RESTART_THRESHOLD`: Minimum container restart count that flags an unstable Pod (default: `5`).
- `STORAGE_S3_FAILURE_THRESHOLD`: Max `s3_access_failures` per `storage_metrics` sample before raising an issue (default: `10`).
- `INGESTION_QUEUE_KEY_THRESHOLD`: Max total (mem + disk) queue keys before flagging an ingestion backlog (default: `100000`).
- `CLUSTER_PENDING_JOBS_THRESHOLD`: Max pending compaction jobs per node before flagging cluster processing backlog (default: `100`).
- `PVC_USAGE_THRESHOLD_PERCENT`: PVC capacity warning threshold, in percent (default: `80`).

### Secrets

- `kubeconfig`: Standard Kubernetes kubeconfig for cluster access and the automatic port-forward.
- `openobserve_credentials` *(optional)*: RunWhen secret with the OpenObserve admin credentials. Format is a JSON object with `username` OR `email` and `password`:
  ```json
  {"username": "root@example.com", "password": "Complexpass#123"}
  ```
  When not provided, the codebundle tries to derive credentials from a Kubernetes Secret in `NAMESPACE` or the workload Pod env.

### Credential resolution

The credentials are resolved **once in Suite Setup** by `resolve-openobserve-credentials.sh` and cached to `./.openobserve_credentials` (mode 600). Every API task reads the cache via the shared helper. The credential **values are never printed**; only the derivation source is logged.

Resolution order (first hit wins):

1. `openobserve_credentials` RunWhen secret (JSON `{username|email, password}`).
2. `OPENOBSERVE_CREDENTIAL_SECRET_NAME` (+ optional `OPENOBSERVE_CREDENTIAL_USER_KEY` / `OPENOBSERVE_CREDENTIAL_PASSWORD_KEY`) read via kubectl.
3. Workload Pod env inference: `ROOT_USER_EMAIL` / `ZO_ROOT_USER_EMAIL` / `ROOT_USER_NAME` and `ROOT_USER_PASSWORD` / `ZO_ROOT_USER_PASSWORD`, following `valueFrom.secretKeyRef` where referenced.
4. `kubectl exec <pod> -- printenv` fallback, gated by `OPENOBSERVE_ALLOW_EXEC=true`.

### Connectivity modes

1. **Auto port-forward (default when `OPENOBSERVE_BASE_URL` is empty)**: each API task runs `kubectl port-forward svc/<service> <local_port>:<openobserve_http_port>` in the background, waits for readiness, and tears it down on exit. Works with ClusterIP-only Services as long as the runner can reach the API server with the kubeconfig.
2. **Direct URL**: set `OPENOBSERVE_BASE_URL` to an in-cluster DNS, ingress, or existing port-forward URL. No port-forward is started.

## Auto-discovery

The generation rule in `.runwhen/generation-rules/k8s-openobserve-healthcheck.yaml` matches a Kubernetes **Deployment or StatefulSet whose name contains `openobserve`** (also matching Helm releases named `openobserve`). One SLX is generated per matched workload in a namespace. Service, PVC, Secret, and ConfigMap discovery happens at runtime inside the namespace.

## Tasks overview

### List OpenObserve Resources in Namespace

Discovers OpenObserve workloads, Services, PVCs, Secrets, and ConfigMaps and adds a topology summary to the report. Raises an issue when no OpenObserve resources are found (wrong namespace or name).

### Check OpenObserve Workload Replica Health

Compares ready vs desired replicas for each OpenObserve Deployment/StatefulSet; flags workloads that are not fully ready or scaled to zero.

### Check OpenObserve Pod Stability

Inspects OpenObserve Pods for non-Running phases, CrashLoopBackOff, failed readiness, and high restart counts to surface instability before it becomes an outage.

### Check OpenObserve API Health

Resolves the admin credentials and OpenObserve Base URL (auto port-forward when not provided) and GETs the health/status endpoints, flagging non-200 responses and authentication failures.

### Check OpenObserve Storage Metrics via API

Calls the OpenObserve `storage_metrics` API to detect S3 storage access failures, WAL/parquet file growth, and upload issues. This is the source of truth for storage health since storage is not observable from inside the container.

### Check OpenObserve Cluster Processing Health

Queries `cluster_info` for per-node pending compaction jobs and flags nodes with a compaction backlog above threshold (storage lifecycle work not keeping up).

### Check OpenObserve Ingestion Queue Health

Queries the `queues` endpoint and flags memory/disk queue key growth that signals ingestion is backing up and data may be delayed or dropped.

### Check OpenObserve Storage Configuration

Reads the OpenObserve workload env for storage topology (`ZO_LOCAL_MODE`, `ZO_DATA_DIR`, `ZO_S3_*`) and validates that S3 settings exist when local mode is disabled.

### Check OpenObserve PVC Capacity

Lists the PVCs backing OpenObserve (capacity, status, reclaim policy) and flags unbound volumes or volumes approaching capacity using kubectl-level data only.

## Notes on API version differences

The exact OpenObserve API endpoints and response field names have changed across releases. The bundle probes multiple candidate paths (`/api/{org}/health` then `/healthz`; `/api/{org}/cluster/info` then `/api/{org}/cluster_info`; etc.) and parses all numeric fields defensively. Missing endpoints or missing fields on newer versions are **not** raised as issues; only genuine failures (non-200 on a supported endpoint, S3 access failures, compaction backlog, queue growth, 401 auth failures) are flagged.

## RBAC

Required: `get`/`list` on Deployment, StatefulSet, Service, Pod, PersistentVolumeClaim, Secret, ConfigMap. Optional (default off): Pod `exec` for credential fallback via `OPENOBSERVE_ALLOW_EXEC=true`.