---
name: k8s-seaweedfs-healthcheck
kind: skill-template
description: Validates SeaweedFS storage health in a Kubernetes namespace—master leadership, volume slots, disk capacity, filer connectivity, and optional S3 probes. Use when triaging or monitoring SeaweedFS Helm installs on Kubernetes.
runtime:
  runbook: runbook.robot
  monitor: sli.robot
  executor: worker
  entrypoint: /home/runwhen/robot-runtime/runrobot.sh
  base_image: rw-base-runtime
platforms: [Kubernetes]
resource_types: [statefulset]
access: read-write
---

# Kubernetes SeaweedFS Storage Health Check

## Summary

This CodeBundle validates SeaweedFS storage health in a Kubernetes namespace deployed via the official Helm chart or compatible operator installs. It inspects master Raft leadership, volume slot availability, disk capacity, filer connectivity, optional S3 gateway operations, configuration audits, GC/compaction signals, capacity projection, and known chart-version issues.

See [README.md](README.md) for additional context.

## Tools

### List SeaweedFS Resources in Namespace `${NAMESPACE}`

Discovers SeaweedFS master, volume, filer, and S3 gateway workloads, services, and PVCs and surfaces missing components.

- **Robot task name**: <code>List SeaweedFS Resources in Namespace `${NAMESPACE}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `list-seaweedfs-resources.sh`
- **Tags**: `Kubernetes`, `SeaweedFS`, `discovery`, `access:read-only`, `data:logs-config`
- **Reads**: `CONTEXT`, `NAMESPACE`, `SEAWEEDFS_RELEASE_NAME`
- **Writes**: `list_seaweedfs_resources_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Check SeaweedFS Workload Replica Health in Namespace `${NAMESPACE}`

Verifies StatefulSets and Deployments for SeaweedFS components have desired replicas ready and flags CrashLoopBackOff or pending pods.

- **Robot task name**: <code>Check SeaweedFS Workload Replica Health in Namespace `${NAMESPACE}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `check-workload-health.sh`
- **Tags**: `Kubernetes`, `SeaweedFS`, `workload`, `access:read-only`, `data:logs-config`
- **Reads**: `CONTEXT`, `NAMESPACE`, `SEAWEEDFS_RELEASE_NAME`
- **Writes**: `workload_health_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Check SeaweedFS Master Cluster Status in Namespace `${NAMESPACE}`

Queries master /cluster/status and /cluster/healthz to validate Raft leadership and master health endpoints.

- **Robot task name**: <code>Check SeaweedFS Master Cluster Status in Namespace `${NAMESPACE}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `check-master-cluster-status.sh`
- **Tags**: `Kubernetes`, `SeaweedFS`, `master`, `access:read-only`, `data:metrics`
- **Reads**: `CONTEXT`, `NAMESPACE`, `SEAWEEDFS_MASTER_SERVICE`
- **Writes**: `master_cluster_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Check SeaweedFS Volume Slot Availability in Namespace `${NAMESPACE}`

Parses /dir/status topology to ensure free volume slots exist before workloads fail on allocation.

- **Robot task name**: <code>Check SeaweedFS Volume Slot Availability in Namespace `${NAMESPACE}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `check-volume-slots.sh`
- **Tags**: `Kubernetes`, `SeaweedFS`, `volumes`, `access:read-only`, `data:metrics`
- **Reads**: `CONTEXT`, `MIN_FREE_VOLUME_SLOTS`, `NAMESPACE`
- **Writes**: `volume_slots_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Check SeaweedFS Volume Server Disk Capacity in Namespace `${NAMESPACE}`

Inspects volume server /status and topology for disk usage, read-only volumes, and min-free-space threshold breaches.

- **Robot task name**: <code>Check SeaweedFS Volume Server Disk Capacity in Namespace `${NAMESPACE}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `check-volume-capacity.sh`
- **Tags**: `Kubernetes`, `SeaweedFS`, `capacity`, `access:read-only`, `data:metrics`
- **Reads**: `CONTEXT`, `MIN_FREE_DISK_PERCENT`, `NAMESPACE`
- **Writes**: `volume_capacity_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Check SeaweedFS Writable Volume Layout in Namespace `${NAMESPACE}`

Evaluates /dir/status layouts for writable volume IDs and flags zero-writable or read-only placement problems.

- **Robot task name**: <code>Check SeaweedFS Writable Volume Layout in Namespace `${NAMESPACE}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `check-writable-layouts.sh`
- **Tags**: `Kubernetes`, `SeaweedFS`, `layout`, `access:read-only`, `data:config`
- **Reads**: `CONTEXT`, `NAMESPACE`
- **Writes**: `writable_layouts_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Check SeaweedFS Filer and Component Connectivity in Namespace `${NAMESPACE}`

Confirms filer health endpoints respond and volume servers appear registered in master topology.

- **Robot task name**: <code>Check SeaweedFS Filer and Component Connectivity in Namespace `${NAMESPACE}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `check-component-connectivity.sh`
- **Tags**: `Kubernetes`, `SeaweedFS`, `connectivity`, `access:read-only`, `data:logs-config`
- **Reads**: `CONTEXT`, `NAMESPACE`, `SEAWEEDFS_FILER_SERVICE`
- **Writes**: `component_connectivity_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Verify SeaweedFS S3 Gateway Operations in Namespace `${NAMESPACE}`

Performs ListBuckets and put/get/delete of a temporary test object against the filer S3 endpoint when enabled.

- **Robot task name**: <code>Verify SeaweedFS S3 Gateway Operations in Namespace `${NAMESPACE}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `verify-s3-gateway.sh`
- **Tags**: `Kubernetes`, `SeaweedFS`, `S3`, `access:read-write`, `data:metrics`
- **Reads**: `CONTEXT`, `NAMESPACE`, `S3_PROBE_BUCKET`, `SEAWEEDFS_S3_ENDPOINT`
- **Writes**: `s3_gateway_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Check SeaweedFS Volume Configuration in Namespace `${NAMESPACE}`

Audits Helm-rendered workload commands, env, mounts, replication, and volume limits for misconfiguration.

- **Robot task name**: <code>Check SeaweedFS Volume Configuration in Namespace `${NAMESPACE}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `check-volume-config.sh`
- **Tags**: `Kubernetes`, `SeaweedFS`, `config`, `access:read-only`, `data:config`
- **Reads**: `CONTEXT`, `NAMESPACE`, `SEAWEEDFS_CHART`, `SEAWEEDFS_RELEASE_NAME`
- **Writes**: `volume_config_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Check SeaweedFS Garbage Collection and Compaction Signals in Namespace `${NAMESPACE}`

Reads master and volume Prometheus metrics for pick-for-write errors, crowded layouts, disk write failures, and delete-blocking read-only volumes.

- **Robot task name**: <code>Check SeaweedFS Garbage Collection and Compaction Signals in Namespace `${NAMESPACE}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `check-gc-compaction.sh`
- **Tags**: `Kubernetes`, `SeaweedFS`, `gc`, `access:read-only`, `data:metrics`
- **Reads**: `CONTEXT`, `MAX_PICK_FOR_WRITE_ERRORS`, `MAX_VOLUME_DISK_ERRORS`, `NAMESPACE`, `SEAWEEDFS_CHART`, `SEAWEEDFS_RELEASE_NAME`
- **Writes**: `gc_compaction_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Check SeaweedFS Capacity Projection in Namespace `${NAMESPACE}`

Evaluates slot and disk utilization headroom and estimates time-to-full when a prior capacity snapshot exists.

- **Robot task name**: <code>Check SeaweedFS Capacity Projection in Namespace `${NAMESPACE}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `check-capacity-projection.sh`
- **Tags**: `Kubernetes`, `SeaweedFS`, `capacity`, `access:read-only`, `data:metrics`
- **Reads**: `CAPACITY_WARN_PERCENT`, `CONTEXT`, `MIN_PROJECTION_HOURS`, `NAMESPACE`, `SEAWEEDFS_CHART`, `SEAWEEDFS_RELEASE_NAME`
- **Writes**: `capacity_projection_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Check SeaweedFS Known Version Issues in Namespace `${NAMESPACE}`

Matches the installed helm.sh/chart version against a curated catalog of SeaweedFS known issues and upgrade cautions.

- **Robot task name**: <code>Check SeaweedFS Known Version Issues in Namespace `${NAMESPACE}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `check-known-issues.sh`
- **Tags**: `Kubernetes`, `SeaweedFS`, `version`, `access:read-only`, `data:config`
- **Reads**: `CONTEXT`, `NAMESPACE`, `SEAWEEDFS_CHART`, `SEAWEEDFS_RELEASE_NAME`
- **Writes**: `known_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


## Monitor

Measures SeaweedFS storage health using workload readiness, master leadership, volume slot availability, and filer connectivity. Produces a value between 0 (failing) and 1 (healthy).

- **Robot file**: `sli.robot`
- **Score range**: `0.0` (failing) to `1.0` (healthy)
- **Aggregation**: arithmetic mean of the sub-checks below
- **Recommended interval**: `300s`

### Sub-checks

The monitor task runs `sli-seaweedfs-dimensions.sh` once and emits four binary sub-metrics (`0` or `1`). The aggregate score is their arithmetic mean.

#### Workload readiness

SeaweedFS StatefulSets and Deployments with `replicas > 0` must have `ready == replicas`.

- **Robot task name**: <code>Score SeaweedFS Health Dimensions in Namespace `${NAMESPACE}`</code>
- **Sub-metric name**: `workload`
- **Underlying script**: `sli-seaweedfs-dimensions.sh`
- **Tags**: `access:read-only`, `data:metrics`
- **Reads**: `CONTEXT`, `NAMESPACE`, `SEAWEEDFS_RELEASE_NAME`, `SEAWEEDFS_CHART`
- **Pass condition**: no SeaweedFS workload has ready replicas below desired count


#### Master health

Master `/cluster/healthz` must respond with an ok/healthy/success body.

- **Robot task name**: <code>Score SeaweedFS Health Dimensions in Namespace `${NAMESPACE}`</code>
- **Sub-metric name**: `master`
- **Underlying script**: `sli-seaweedfs-dimensions.sh`
- **Tags**: `access:read-only`, `data:metrics`
- **Reads**: `CONTEXT`, `NAMESPACE`, `SEAWEEDFS_RELEASE_NAME`, `SEAWEEDFS_CHART`
- **Pass condition**: master health endpoint reachable and healthy


#### Volume slot availability

Master `/dir/status` topology free slots must meet `MIN_FREE_VOLUME_SLOTS`.

- **Robot task name**: <code>Score SeaweedFS Health Dimensions in Namespace `${NAMESPACE}`</code>
- **Sub-metric name**: `volume_slots`
- **Underlying script**: `sli-seaweedfs-dimensions.sh`
- **Tags**: `access:read-only`, `data:metrics`
- **Reads**: `CONTEXT`, `MIN_FREE_VOLUME_SLOTS`, `NAMESPACE`, `SEAWEEDFS_RELEASE_NAME`, `SEAWEEDFS_CHART`
- **Pass condition**: topology free slots ≥ `MIN_FREE_VOLUME_SLOTS` (default `1`)


#### Filer connectivity

A filer pod must exist and respond on `/healthz` or `/status`.

- **Robot task name**: <code>Score SeaweedFS Health Dimensions in Namespace `${NAMESPACE}`</code>
- **Sub-metric name**: `connectivity`
- **Underlying script**: `sli-seaweedfs-dimensions.sh`
- **Tags**: `access:read-only`, `data:metrics`
- **Reads**: `CONTEXT`, `NAMESPACE`, `SEAWEEDFS_RELEASE_NAME`, `SEAWEEDFS_CHART`
- **Pass condition**: filer pod present and health endpoint responds

| Name | Type | Description | Default | Required |
|---|---|---|---|---|
| `KUBERNETES_DISTRIBUTION_BINARY` | string | Kubernetes CLI binary (kubectl or oc). | `kubectl` | no |
| `CONTEXT` | string | Kubernetes context for the target cluster. | — | yes |
| `NAMESPACE` | string | Namespace where SeaweedFS is deployed. | — | yes |
| `SEAWEEDFS_RELEASE_NAME` | string | Helm release instance label (parent release for subchart installs). | `` | no |
| `SEAWEEDFS_CHART` | string | Exact helm.sh/chart label for the SeaweedFS subchart (e.g. seaweedfs-4.25.0). | `` | no |
| `SEAWEEDFS_MASTER_SERVICE` | string | Override master service host:port when auto-discovery is insufficient. | `` | no |
| `SEAWEEDFS_FILER_SERVICE` | string | Override filer service host:port when auto-discovery is insufficient. | `` | no |
| `SEAWEEDFS_S3_ENDPOINT` | string | Override S3 endpoint URL for gateway probe. | `` | no |
| `MIN_FREE_VOLUME_SLOTS` | string | Minimum free volume slots required before raising an issue. | `1` | no |
| `MIN_FREE_DISK_PERCENT` | string | Minimum free disk percentage required on volume servers. | `10` | no |
| `S3_PROBE_BUCKET` | string | Existing bucket for S3 probe; temporary object prefix is used. | `` | no |
| `CAPACITY_WARN_PERCENT` | string | Slot or disk utilization percent that triggers capacity projection warnings. | `80` | no |
| `MIN_PROJECTION_HOURS` | string | Hours-until-full estimate that triggers slot exhaustion projection issues. | `24` | no |
| `MAX_PICK_FOR_WRITE_ERRORS` | string | Master pick-for-write error counter threshold for GC/compaction checks. | `100` | no |
| `MAX_VOLUME_DISK_ERRORS` | string | Volume server disk write error counter threshold for GC/compaction checks. | `50` | no |

## Secrets

| Name | Type | Description | Required |
|---|---|---|---|
| `kubeconfig` | string | Kubernetes kubeconfig YAML with read access to the namespace. | yes |
| `seaweedfs_s3_credentials` | string | Optional JSON with `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` for the S3 gateway probe. | no |

## Outputs

- Monitor sub-metrics: `workload`, `master`, `volume_slots`, `connectivity` (each `0` or `1`)
- `list_seaweedfs_resources_issues.json`
- `workload_health_issues.json`
- `master_cluster_issues.json`
- `volume_slots_issues.json`
- `volume_capacity_issues.json`
- `writable_layouts_issues.json`
- `component_connectivity_issues.json`
- `s3_gateway_issues.json`
- `volume_config_issues.json`
- `gc_compaction_issues.json`
- `capacity_projection_issues.json`
- `known_issues.json`

## How to invoke

### Production (RunWhen runner / worker)

The platform **runner** schedules work on a location **worker**. The worker
image (`rw-base-runtime`) executes Robot via `runrobot.sh` with
`RW_PATH_TO_ROBOT` set to the bound path under `/home/runwhen/collection/`.

- **Runbook**: `codebundles/k8s-seaweedfs-healthcheck/runbook.robot`
- **Monitor**: `codebundles/k8s-seaweedfs-healthcheck/sli.robot`

### Local development (devcontainer only)

`ro` is a dev-time wrapper in `codecollection-devtools` — not the enterprise runtime.

```bash
cd codebundles/k8s-seaweedfs-healthcheck
export RW_MODE=dev
export RW_FROM_FILE='{"kubeconfig":"/path/to/kubeconfig"}'
export CONTEXT=...
export NAMESPACE=...
export SEAWEEDFS_RELEASE_NAME=...   # optional; chart-aware auto-discovery when empty
export SEAWEEDFS_CHART=...          # optional; e.g. seaweedfs-4.25.0
ro runbook.robot
ro sli.robot
```

### Standalone scripts (no Robot)


Set the input variables above, then run the matching script:

```bash
cd codebundles/k8s-seaweedfs-healthcheck
export KUBERNETES_DISTRIBUTION_BINARY=...
export CONTEXT=...
export NAMESPACE=...
export SEAWEEDFS_RELEASE_NAME=...
bash check-capacity-projection.sh
bash check-component-connectivity.sh
bash check-gc-compaction.sh
bash check-known-issues.sh
bash check-master-cluster-status.sh
bash check-volume-capacity.sh
bash check-volume-config.sh
bash check-volume-slots.sh
bash check-workload-health.sh
bash check-writable-layouts.sh
bash list-seaweedfs-resources.sh
bash seaweedfs-lib.sh
# ... and 2 more scripts
```

## Source files

- `runbook.robot` — orchestrates tools and raises issues
- `sli.robot` — monitor scoring (`sli.robot` runtime file)
- `check-capacity-projection.sh` — Bash helper script `check-capacity-projection.sh`.
- `check-component-connectivity.sh` — Bash helper script `check-component-connectivity.sh`.
- `check-gc-compaction.sh` — Bash helper script `check-gc-compaction.sh`.
- `check-known-issues.sh` — Bash helper script `check-known-issues.sh`.
- `check-master-cluster-status.sh` — Bash helper script `check-master-cluster-status.sh`.
- `check-volume-capacity.sh` — Bash helper script `check-volume-capacity.sh`.
- `check-volume-config.sh` — Bash helper script `check-volume-config.sh`.
- `check-volume-slots.sh` — Bash helper script `check-volume-slots.sh`.
- `check-workload-health.sh` — Bash helper script `check-workload-health.sh`.
- `check-writable-layouts.sh` — Bash helper script `check-writable-layouts.sh`.
- `list-seaweedfs-resources.sh` — Bash helper script `list-seaweedfs-resources.sh`.
- `seaweedfs-lib.sh` — Bash helper script `seaweedfs-lib.sh`.
- `sli-seaweedfs-dimensions.sh` — Bash helper script `sli-seaweedfs-dimensions.sh`.
- `verify-s3-gateway.sh` — Bash helper script `verify-s3-gateway.sh`.
