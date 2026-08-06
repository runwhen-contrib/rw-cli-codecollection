# Kubernetes Airflow Workload Diagnostics

This CodeBundle collects Kubernetes-centric health signals for Apache Airflow installations: workload controllers (webserver, scheduler, workers, triggerer), pod readiness and restarts, recent Warning events, PVCs for logs and DAGs, targeted scheduler log excerpts, and executor-style pod status. All tasks are read-only and do not trigger DAG runs or mutate workloads.

## Overview

- **Workload controllers**: Lists Deployments, StatefulSets, and DaemonSets that match the Airflow label selector or name prefix and compares desired versus ready replicas.
- **Pod health**: Checks Airflow-labeled pods for phase, Ready condition, restart counts, and recent termination reasons (for example OOMKilled).
- **Events**: Surfaces Warning events in the lookback window for Airflow-related object names.
- **Storage**: Summarizes PVCs tied to Airflow pods or common volume name patterns and flags non-Bound phases.
- **Scheduler logs**: Samples scheduler pod logs for DAG import errors and database connectivity hints.
- **Executors**: Best-effort summary of worker or executor-related pods that are Pending or have OOM terminations.
- **SLI**: Publishes a 0–1 health score from workload readiness, pod readiness, and Warning event volume (see `sli.robot`).

## Configuration

### Required variables

- `CONTEXT`: Kubernetes context to use.
- `NAMESPACE`: Namespace that contains the Airflow release.

### Optional variables

- `AIRFLOW_LABEL_SELECTOR`: Label selector for Airflow workloads (default: `app.kubernetes.io/name=airflow`).
- `AIRFLOW_DEPLOYMENT_NAME_PREFIX`: Extra name prefix used when labels are inconsistent (default: `airflow`).
- `RW_LOOKBACK_WINDOW`: Time window for events and log sampling, for example `30m` or `1h` (default: `1h`).
- `KUBERNETES_DISTRIBUTION_BINARY`: `kubectl` or `oc` (default: `kubectl`).

### SLI-only optional variables

- `AIRFLOW_SLI_EVENT_THRESHOLD`: Maximum number of Warning events in the lookback window before the events sub-score fails (default: `8`).

### Bash script defaults (not imported in `runbook.robot`)

- `AIRFLOW_RESTART_WARN_THRESHOLD`: Total container restart count above which the pod health task raises a warning (default: `10`).

### Secrets

- `kubeconfig`: Standard kubeconfig with read-only `get`, `list`, `describe`, and `logs` on workloads and events in the target namespace.

## Tasks overview

### List Airflow Workloads in Namespace

Discovers Deployments, StatefulSets, and DaemonSets via the label selector and optional name prefix merge; raises issues when ready replicas are below desired counts.

### Check Airflow Pod Health and Restarts in Namespace

Evaluates Airflow-labeled pods for phase, Ready condition, high restart counts, and recent container termination reasons.

### Fetch Recent Events for Airflow Resources in Namespace

Collects Warning events since the lookback cutoff for involved objects related to Airflow naming or workloads.

### Summarize PVC Status for Airflow Data Volumes in Namespace

Lists PVCs referenced by Airflow pods or matching common DAGs, logs, or plugins name patterns; issues when a PVC is not Bound.

### Sample Scheduler Logs for DAG Import Errors in Namespace

Tails recent scheduler logs and flags traceback, import, or database connectivity patterns.

### Check Worker or KubernetesExecutor Pod Saturation in Namespace

Surfaces Pending executor-related pods and OOMKilled containers when Celery or executor components are present.
