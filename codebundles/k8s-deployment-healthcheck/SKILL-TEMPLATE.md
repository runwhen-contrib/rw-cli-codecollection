---
name: k8s-deployment-healthcheck
kind: skill-template
description: Triages issues related to a deployment and its replicas. Use when triaging or monitoring Kubernetes, AKS, EKS workloads with skill template `k8s-deployment-healthcheck`.
runtime:
  runbook: runbook.robot
  monitor: sli.robot
  executor: worker
  entrypoint: /home/runwhen/robot-runtime/runrobot.sh
  base_image: rw-base-runtime
platforms: [Kubernetes, AKS, EKS, GKE, OpenShift]
resource_types: [deployment]
access: read-only
---

# Kubernetes Deployment Triage

## Summary

This codebundle provides a suite of tasks aimed at triaging issues related to a deployment and its replicas in Kubernetes clusters.

See [README.md](README.md) for additional context.

## Tools

### Analyze Application Log Patterns for Deployment `${DEPLOYMENT_NAME}` in Namespace `${NAMESPACE}`

Fetches and analyzes logs from the deployment pods for errors, connection issues, and other patterns that indicate application health problems. Note: Warning messages about missing log files for excluded containers (like linkerd-proxy, istio-proxy) are expected and harmless.

- **Robot task name**: <code>Analyze Application Log Patterns for Deployment `${DEPLOYMENT_NAME}` in Namespace `${NAMESPACE}`</code>
- **Robot file**: `runbook.robot`
- **Tags**: —
- **Reads**: `CONTEXT`, `DEPLOYMENT_NAME`, `LOGS_EXCLUDE_PATTERN`, `LOG_AGE`, `LOG_ANALYSIS_DEPTH`, `LOG_SEVERITY_THRESHOLD`, `NAMESPACE`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Detect Event Anomalies for Deployment `${DEPLOYMENT_NAME}` in Namespace `${NAMESPACE}`

Analyzes Kubernetes event patterns to identify anomalies such as sudden spikes in event rates, unusual patterns, or recurring issues that might indicate underlying problems with controllers, resources, or deployments.

- **Robot task name**: <code>Detect Event Anomalies for Deployment `${DEPLOYMENT_NAME}` in Namespace `${NAMESPACE}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `event_anomalies.sh`
- **Tags**: —
- **Reads**: `ANOMALY_THRESHOLD`, `DEPLOYMENT_NAME`, `NAMESPACE`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Fetch Deployment Logs for `${DEPLOYMENT_NAME}` in Namespace `${NAMESPACE}`

Fetches and displays deployment logs in the report for manual review. Note: Issues are not created by this task - see "Analyze Application Log Patterns" for automated issue detection.

- **Robot task name**: <code>Fetch Deployment Logs for `${DEPLOYMENT_NAME}` in Namespace `${NAMESPACE}`</code>
- **Robot file**: `runbook.robot`
- **Tags**: —
- **Reads**: `CONTAINER_NAME`, `CONTEXT`, `DEPLOYMENT_NAME`, `KUBERNETES_DISTRIBUTION_BINARY`, `LOG_AGE`, `LOG_LINES`, `NAMESPACE`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Check Liveness Probe Configuration for Deployment `${DEPLOYMENT_NAME}`

Validates if a Liveness probe has possible misconfigurations

- **Robot task name**: <code>Check Liveness Probe Configuration for Deployment `${DEPLOYMENT_NAME}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `validate_probes.sh`
- **Tags**: —
- **Reads**: `CONTEXT`, `DEPLOYMENT_NAME`, `NAMESPACE`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Check Readiness Probe Configuration for Deployment `${DEPLOYMENT_NAME}` in Namespace `${NAMESPACE}`

Validates if a readiness probe has possible misconfigurations

- **Robot task name**: <code>Check Readiness Probe Configuration for Deployment `${DEPLOYMENT_NAME}` in Namespace `${NAMESPACE}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `validate_probes.sh`
- **Tags**: —
- **Reads**: `CONTEXT`, `DEPLOYMENT_NAME`, `NAMESPACE`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Inspect Deployment Warning Events for `${DEPLOYMENT_NAME}` in Namespace `${NAMESPACE}`

Fetches warning events related to the deployment workload in the namespace and triages any issues found in the events.

- **Robot task name**: <code>Inspect Deployment Warning Events for `${DEPLOYMENT_NAME}` in Namespace `${NAMESPACE}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `workload_issues.sh`
- **Tags**: `access:read-only`, `events`, `workloads`, `errors`, `warnings`, `get`, `deployment`, `${DEPLOYMENT_NAME}`, `data:config`
- **Reads**: `CONTEXT`, `DEPLOYMENT_NAME`, `KUBERNETES_DISTRIBUTION_BINARY`, `NAMESPACE`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Check Deployment Replica Status for `${DEPLOYMENT_NAME}` in Namespace `${NAMESPACE}`

Inspects the deployment replica status including desired vs available replicas and identifies any scaling issues.

- **Robot task name**: <code>Check Deployment Replica Status for `${DEPLOYMENT_NAME}` in Namespace `${NAMESPACE}`</code>
- **Robot file**: `runbook.robot`
- **Tags**: `access:read-only`, `deployment`, `replicas`, `scaling`, `status`, `${DEPLOYMENT_NAME}`, `data:config`
- **Reads**: `CONTEXT`, `DEPLOYMENT_NAME`, `KUBERNETES_DISTRIBUTION_BINARY`, `NAMESPACE`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Inspect Container Restarts for Deployment `${DEPLOYMENT_NAME}` in Namespace `${NAMESPACE}`

Checks for container restarts and provides details on restart patterns that might indicate application issues.

- **Robot task name**: <code>Inspect Container Restarts for Deployment `${DEPLOYMENT_NAME}` in Namespace `${NAMESPACE}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `container_restarts.sh`
- **Tags**: `access:read-only`, `containers`, `restarts`, `pods`, `deployment`, `${DEPLOYMENT_NAME}`, `data:config`
- **Reads**: `CONTAINER_RESTART_AGE`, `CONTAINER_RESTART_THRESHOLD`, `DEPLOYMENT_NAME`, `NAMESPACE`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Identify Recent Configuration Changes for Deployment `${DEPLOYMENT_NAME}` in Namespace `${NAMESPACE}`

Identifies recent configuration changes from ReplicaSet analysis that might be related to current issues.

- **Robot task name**: <code>Identify Recent Configuration Changes for Deployment `${DEPLOYMENT_NAME}` in Namespace `${NAMESPACE}`</code>
- **Robot file**: `runbook.robot`
- **Tags**: —
- **Reads**: `CONTEXT`, `DEPLOYMENT_NAME`, `NAMESPACE`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Check HPA Health for Deployment `${DEPLOYMENT_NAME}` in Namespace `${NAMESPACE}`

Checks if a HorizontalPodAutoscaler exists for the deployment and validates its configuration and current status.

- **Robot task name**: <code>Check HPA Health for Deployment `${DEPLOYMENT_NAME}` in Namespace `${NAMESPACE}`</code>
- **Robot file**: `runbook.robot`
- **Tags**: —
- **Reads**: `CONTEXT`, `DEPLOYMENT_NAME`, `KUBERNETES_DISTRIBUTION_BINARY`, `NAMESPACE`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


## Monitor

This SLI uses kubectl to score deployment health. Produces a value between 0 (completely failing the test) and 1 (fully passing the test). Looks for container restarts, critical log errors, pods not ready, deployment status, and recent events.

- **Robot file**: `sli.robot`
- **Score range**: `0.0` (failing) to `1.0` (healthy)
- **Aggregation**: arithmetic mean of the sub-checks below
- **Recommended interval**: `180s`

### Sub-checks

#### Get Container Restarts and Score for Deployment `${DEPLOYMENT_NAME}`

Counts the total sum of container restarts within a timeframe and determines if they're beyond a threshold.

- **Robot task name**: <code>Get Container Restarts and Score for Deployment `${DEPLOYMENT_NAME}`</code>
- **Sub-metric name**: `container_restarts`
- **Tags**: `Restarts`, `Pods`, `Containers`, `Count`, `Status`, `data:config`
- **Reads**: `CONTAINER_RESTART_AGE`, `CONTAINER_RESTART_THRESHOLD`, `CONTEXT`, `DEPLOYMENT_NAME`, `KUBERNETES_DISTRIBUTION_BINARY`, `NAMESPACE`
- **Pass condition**: `${restart_count} <= ${threshold}`


#### Get Critical Log Errors and Score for Deployment `${DEPLOYMENT_NAME}`

Fetches logs and checks for critical error patterns that indicate application failures.

- **Robot task name**: <code>Get Critical Log Errors and Score for Deployment `${DEPLOYMENT_NAME}`</code>
- **Sub-metric name**: `log_errors`
- **Tags**: `logs`, `errors`, `critical`, `patterns`, `data:logs-regexp`
- **Reads**: `CONTEXT`, `DEPLOYMENT_NAME`, `LOGS_EXCLUDE_PATTERN`, `MAX_LOG_BYTES`, `MAX_LOG_LINES`, `NAMESPACE`


#### Get NotReady Pods Score for Deployment `${DEPLOYMENT_NAME}`

Fetches a count of unready pods for the specific deployment.

- **Robot task name**: <code>Get NotReady Pods Score for Deployment `${DEPLOYMENT_NAME}`</code>
- **Sub-metric name**: `pod_readiness`
- **Tags**: `access:read-only`, `Pods`, `Status`, `Phase`, `Ready`, `Unready`, `Running`, `data:config`
- **Reads**: `CONTEXT`, `DEPLOYMENT_NAME`, `KUBERNETES_DISTRIBUTION_BINARY`, `NAMESPACE`
- **Pass condition**: `${unready_count} == 0`


#### Get Deployment Replica Status and Score for `${DEPLOYMENT_NAME}`

Checks if deployment has the expected number of ready replicas and is available.

- **Robot task name**: <code>Get Deployment Replica Status and Score for `${DEPLOYMENT_NAME}`</code>
- **Sub-metric name**: `replica_status`
- **Tags**: `deployment`, `replicas`, `status`, `availability`, `data:config`
- **Reads**: `CONTEXT`, `DEPLOYMENT_NAME`, `KUBERNETES_DISTRIBUTION_BINARY`, `NAMESPACE`
- **Pass condition**: `${ready_replicas} >= 1 and "${available_status}" == "True"`


#### Get Recent Warning Events Score for `${DEPLOYMENT_NAME}`

Checks for recent warning events related to the deployment within a short time window, with filtering to reduce noise.

- **Robot task name**: <code>Get Recent Warning Events Score for `${DEPLOYMENT_NAME}`</code>
- **Sub-metric name**: `warning_events`
- **Tags**: `events`, `warnings`, `recent`, `fast`, `data:config`
- **Reads**: `CONTEXT`, `DEPLOYMENT_NAME`, `EVENT_AGE`, `EVENT_THRESHOLD`, `KUBERNETES_DISTRIBUTION_BINARY`, `NAMESPACE`
- **Pass condition**: `${event_count} <= ${threshold} else (0.5 if ${event_count} <= ${threshold_doubled}`


## Inputs

| Name | Type | Description | Default | Required |
|---|---|---|---|---|
| `KUBERNETES_DISTRIBUTION_BINARY` | string | Which binary to use for Kubernetes CLI commands. | `kubectl` | no |
| `CONTEXT` | string | Which Kubernetes context to operate within. | — | yes |
| `NAMESPACE` | string | The name of the Kubernetes namespace to scope actions and searching to. | — | yes |
| `DEPLOYMENT_NAME` | string | The name of the deployment to triage. | — | yes |
| `LOG_LINES` | string | The number of log lines to fetch from the pods when inspecting logs. | `100` | no |
| `LOG_AGE` | string | The age of logs to fetch from pods, used for log analysis tasks. | `10m` | no |
| `LOG_ANALYSIS_DEPTH` | string | The depth of log analysis to perform - basic, standard, or comprehensive. | `standard` | no |
| `LOG_SEVERITY_THRESHOLD` | string | The minimum severity level for creating issues (1=critical, 2=high, 3=medium, 4=low, 5=info). | `3` | no |
| `LOG_PATTERN_CATEGORIES` | string | Comma-separated list of log pattern categories to scan for. | `GenericError,AppFailure,Connection,Timeout,Auth,Exceptions,Resource,HealthyRecovery` | no |
| `ANOMALY_THRESHOLD` | string | The threshold for detecting event anomalies based on events per minute. | `5` | no |
| `LOGS_ERROR_PATTERN` | string | The error pattern to use when grep-ing logs. | `error|ERROR` | no |
| `LOGS_EXCLUDE_PATTERN` | string | Pattern used to exclude entries from log analysis when searching for errors. Use regex patterns to filter out false positives like JSON structures. | `"errors":\\s*\\[\\]|\\bINFO\\b|\\bDEBUG\\b|\\bTRACE\\b|\\bSTART\\s*-\\s*|\\bSTART\\s*method\\b` | no |
| `LOG_SCAN_TIMEOUT` | string | Timeout in seconds for log scanning operations. Increase this value if log scanning times out on large log files. | `300` | no |
| `EXCLUDED_CONTAINER_NAMES` | string | Comma-separated list of container names to exclude from log analysis (e.g., linkerd-proxy, istio-proxy, vault-agent). | `linkerd-proxy,istio-proxy,vault-agent` | no |
| `CONTAINER_NAME` | string | Optional: the specific container name to fetch logs from. If not set, the primary application container is auto-detected by excluding known sidecars. | `` | yes |
| `CONTAINER_RESTART_AGE` | string | The time window (in (h) hours or (m) minutes) to search for container restarts. Only containers that restarted within this time period will be reported. | `10m` | no |
| `CONTAINER_RESTART_THRESHOLD` | string | The minimum number of restarts required to trigger an issue. Containers with restart counts below this threshold will be ignored. | `1` | no |
| `MAX_LOG_LINES` | string | Maximum number of log lines to fetch per container to prevent API overload. | `100` | no |
| `MAX_LOG_BYTES` | string | Maximum log size in bytes to fetch per container to prevent API overload. | `256000` | no |
| `EVENT_AGE` | string | The time window to check for recent warning events. | `10m` | no |
| `EVENT_THRESHOLD` | string | The maximum number of critical warning events allowed before scoring is reduced. | `2` | no |
| `CHECK_SERVICE_ENDPOINTS` | string | Whether to check service endpoint health. Set to 'false' if deployment doesn't have associated services. | `true` | no |

## Secrets

| Name | Description | Required |
|---|---|---|
| `kubeconfig` | The kubernetes kubeconfig yaml containing connection configuration used to connect to cluster(s). | yes |

## Outputs

- Monitor health score (`0.0`–`1.0`) pushed by `sli.robot`

## How to invoke

### Production (RunWhen runner / worker)

The platform **runner** schedules work on a location **worker**. The worker
image (`rw-base-runtime`) executes Robot via `runrobot.sh` with
`RW_PATH_TO_ROBOT` set to the bound path under `/home/runwhen/collection/`.

- **Runbook**: `codebundles/k8s-deployment-healthcheck/runbook.robot`
- **Monitor**: `codebundles/k8s-deployment-healthcheck/sli.robot`

### Local development (devcontainer only)

`ro` is a dev-time wrapper in `codecollection-devtools` — not the enterprise runtime.

```bash
cd codebundles/k8s-deployment-healthcheck
export KUBERNETES_DISTRIBUTION_BINARY=...
export CONTEXT=...
export NAMESPACE=...
export DEPLOYMENT_NAME=...
export LOG_LINES=...
export LOG_AGE=...
ro runbook.robot
```

### Standalone scripts (no Robot)


Set the input variables above, then run the matching script:

```bash
cd codebundles/k8s-deployment-healthcheck
export KUBERNETES_DISTRIBUTION_BINARY=...
export CONTEXT=...
export NAMESPACE=...
export DEPLOYMENT_NAME=...
bash check_replicaset.sh
bash container_restarts.sh
bash deployment_logs.sh
bash event_anomalies.sh
bash track_deployment_config_changes.sh
bash validate_probes.sh
bash workload_issues.sh
bash workload_next_steps.sh
```

## Source files

- `runbook.robot` — orchestrates tools and raises issues
- `sli.robot` — monitor scoring (`sli.robot` runtime file)
- `check_replicaset.sh` — Bash helper script `check_replicaset.sh`.
- `container_restarts.sh` — Bash helper script `container_restarts.sh`.
- `deployment_logs.sh` — Bash helper script `deployment_logs.sh`.
- `event_anomalies.sh` — Bash helper script `event_anomalies.sh`.
- `track_deployment_config_changes.sh` — Bash helper script `track_deployment_config_changes.sh`.
- `validate_probes.sh` — Bash helper script `validate_probes.sh`.
- `workload_issues.sh` — Bash helper script `workload_issues.sh`.
- `workload_next_steps.sh` — Bash helper script `workload_next_steps.sh`.
