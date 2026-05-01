# Kubernetes StatefulSet Healthcheck

This codebundle ships two robots that work together to keep an eye on a single Kubernetes StatefulSet:

- `sli.robot` – a lightweight health score (0.0 – 1.0) published as a RunWhen SLI.
- `runbook.robot` – a deeper triage flow for when something is wrong.

## SLI (`sli.robot`)

The SLI uses `kubectl` to score StatefulSet health on a short interval and pushes a value between `0`
(completely failing) and `1` (fully healthy). It is modeled after the `k8s-deployment-healthcheck` SLI
but adapted to StatefulSet semantics (revision/rollout status, PersistentVolumeClaim binding, and
label selection via `spec.selector.matchLabels`).

The final score is the average of the following sub-metrics, each also pushed under `sub_name`:

| Sub-metric          | What it checks                                                                                          |
|---------------------|---------------------------------------------------------------------------------------------------------|
| `container_restarts`| Sum of recent container restarts across the StatefulSet's pods vs. a threshold.                        |
| `log_errors`        | Critical log patterns (exceptions, panics, crash loops, storage/quorum failures, stack traces).        |
| `pod_readiness`     | Number of pods that are not `Ready` (excluding `PodCompleted`).                                        |
| `replica_status`    | `readyReplicas` vs. `replicas`, plus `updatedReplicas` / `currentRevision == updateRevision` rollout.  |
| `pvc_status`        | PVCs created by `volumeClaimTemplates` for the StatefulSet are all `Bound`.                            |
| `warning_events`    | Count of recent `Warning` events on the StatefulSet, its pods, and its PVCs vs. a threshold.           |

### Scaled-to-zero handling

If `spec.replicas == 0`, the SLI treats the StatefulSet as intentionally down and returns a score of
`1.0` with context in the report. This mirrors the deployment SLI behavior and distinguishes
intentional downtime from outages.

### Configuration

The SLI accepts the following variables (defaults shown):

- `kubeconfig` (secret) – kubeconfig used to talk to the cluster.
- `KUBERNETES_DISTRIBUTION_BINARY` – `kubectl` or `oc` (default: `kubectl`).
- `CONTEXT` – the Kubernetes context.
- `NAMESPACE` – the namespace the StatefulSet lives in.
- `STATEFULSET_NAME` – the StatefulSet to score.
- `CONTAINER_RESTART_AGE` – time window to look for restarts (default: `10m`).
- `CONTAINER_RESTART_THRESHOLD` – max restarts considered healthy (default: `1`, template sets `2`).
- `EVENT_AGE` – time window for recent warning events (default: `10m`).
- `EVENT_THRESHOLD` – max warning events considered healthy (default: `2`).
- `MAX_LOG_LINES` / `MAX_LOG_BYTES` – per-container log sampling limits.
- `LOGS_EXCLUDE_PATTERN` – regex to drop noisy log entries before scoring.
- `EXCLUDED_CONTAINER_NAMES` – comma-separated sidecars to skip in log analysis.

Critical log patterns live in `sli_critical_patterns.json` alongside the robot.

## Runbook (`runbook.robot`)

The runbook performs deeper triage (log pattern analysis, probe validation, container restart
forensics, warning events, PVC health, config-change detection, etc.) and raises issues. See
`runbook.robot` for the full task list.

### Runbook configuration

- `kubeconfig`: kubeconfig secret for the cluster.
- `KUBERNETES_DISTRIBUTION_BINARY`: `kubectl` or `oc` (default: `kubectl`).
- `CONTEXT`: Kubernetes context to operate within.
- `NAMESPACE`: namespace of the StatefulSet.
- `STATEFULSET_NAME`: the StatefulSet to triage.
- `LABELS`: additional label selector used by some triage tasks.

## Requirements

- A kubeconfig with read permissions on `statefulsets`, `pods`, `events`, and `persistentvolumeclaims`
  in the target namespace.

## TODO

- [ ] Add additional documentation.
- [ ] Review label usage for ephemeral sets.
