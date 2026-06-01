---
name: gke-cluster-health
kind: skill-template
description: Identify issues affecting GKE Clusters in a GCP Project. Use when triaging or monitoring GCP, GKE workloads with skill template `gke-cluster-health`.
runtime:
  runbook: runbook.robot
  executor: worker
  entrypoint: /home/runwhen/robot-runtime/runrobot.sh
  base_image: rw-base-runtime
platforms: [GCP, GKE]
resource_types: [gke_cluster]
access: read-only
---

# GKE Cluster Health

## Summary

This codebundle performs comprehensive health checking for Google Kubernetes Engine (GKE) clusters, including node pool analysis, instance group evaluation, and resource optimization recommendations.

See [README.md](README.md) for additional context.

## Tools

### Identify GKE Service Account Issues in GCP Project `${GCP_PROJECT_ID}`

Checks for IAM Service Account issues that can affect Cluster functionality

- **Robot task name**: <code>Identify GKE Service Account Issues in GCP Project `${GCP_PROJECT_ID}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `sa_check.sh`
- **Tags**: `gcloud`, `gke`, `gcp`, `access:read-only`, `data:config`
- **Reads**: —
- **Writes**: `issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Fetch GKE Recommendations for GCP Project `${GCP_PROJECT_ID}`

Fetch and summarize GCP Recommendations for GKE Clusters

- **Robot task name**: <code>Fetch GKE Recommendations for GCP Project `${GCP_PROJECT_ID}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `gcp_recommendations.sh`
- **Tags**: `recommendations`, `gcloud`, `gke`, `gcp`, `access:read-only`, `data:config`
- **Reads**: —
- **Writes**: `recommendations_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Check Kubernetes Version Support for GKE Clusters in GCP Project `${GCP_PROJECT_ID}`

Checks whether GKE clusters are running deprecated or extended-support Kubernetes versions and estimates cost impact. GKE charges a $0.50/hr/cluster surcharge for versions in extended support (6x standard cost). GKE Enterprise includes extended support at no additional charge.

- **Robot task name**: <code>Check Kubernetes Version Support for GKE Clusters in GCP Project `${GCP_PROJECT_ID}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `check_gke_version_support.sh`
- **Tags**: `version`, `deprecation`, `cost`, `extended-support`, `gcloud`, `gke`, `gcp`, `access:read-only`, `data:config`
- **Reads**: `GCP_PROJECT_ID`
- **Writes**: `version_support_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Fetch GKE Cluster Health for GCP Project `${GCP_PROJECT_ID}`

Using kubectl, fetch overall basic health of the cluster by checking unhealthy pods, overutilized nodes, and underutilized clusters with cost savings opportunities. Analyzes resource utilization and provides MSRP-based cost optimization recommendations. Useful when stackdriver is not available. Requires iam permissions to fetch cluster credentials with viewer rights.

- **Robot task name**: <code>Fetch GKE Cluster Health for GCP Project `${GCP_PROJECT_ID}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `cluster_health.sh`
- **Tags**: `health`, `crashloopbackoff`, `cost-optimization`, `underutilization`, `gcloud`, `gke`, `gcp`, `access:read-only`, `data:config`
- **Reads**: —
- **Writes**: `cluster_health_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Check for Quota Related GKE Autoscaling Issues in GCP Project `${GCP_PROJECT_ID}`

Ensure that GKE Autoscaling will not be blocked by Quota constraints

- **Robot task name**: <code>Check for Quota Related GKE Autoscaling Issues in GCP Project `${GCP_PROJECT_ID}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `quota_check.sh`
- **Tags**: `quota`, `autoscaling`, `gcloud`, `gke`, `gcp`, `access:read-only`, `data:config`
- **Reads**: —
- **Writes**: `region_quota_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Validate GKE Node Sizes for GCP Project `${GCP_PROJECT_ID}`

Analyse live pod requests/limits, node usage,  and propose suitable GKE node machine types.

- **Robot task name**: <code>Validate GKE Node Sizes for GCP Project `${GCP_PROJECT_ID}`</code>
- **Robot file**: `runbook.robot`
- **Tags**: `sizing`, `gke`, `gcloud`, `access:read-only`, `node`, `autoscale`, `data:config`
- **Reads**: —
- **Writes**: `node_size_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Fetch GKE Cluster Operations for GCP Project `${GCP_PROJECT_ID}`

Fetches GKE Operations and identify stuck or failed tasks.

- **Robot task name**: <code>Fetch GKE Cluster Operations for GCP Project `${GCP_PROJECT_ID}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `cluster_operations.sh`
- **Tags**: `sizing`, `gke`, `gcloud`, `access:read-only`, `cluster`, `operations`, `data:config`
- **Reads**: —
- **Writes**: `cluster_operations_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Check Node Pool Health for GCP Project `${GCP_PROJECT_ID}`

Performs comprehensive node pool health checking including instance group logs, compute operations, and Kubernetes events to surface hard-to-find issues like region exhaustion and quota blocking.

- **Robot task name**: <code>Check Node Pool Health for GCP Project `${GCP_PROJECT_ID}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `node_pool_health.sh`
- **Tags**: `nodepool`, `health`, `events`, `quota`, `exhaustion`, `gcloud`, `gke`, `gcp`, `access:read-only`, `data:config`
- **Reads**: —
- **Writes**: `node_pool_health_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


## Inputs

| Name | Type | Description | Default | Required |
|---|---|---|---|---|
| `GCP_PROJECT_ID` | string | The GCP Project ID to scope the API to. | — | yes |
| `CRITICAL_NAMESPACES` | string | A comma separated list of namespaces which are critical. If pods are unhealthy in these namespaces, a severity 1 issue is raised. | `kube-system,flux-system,cert-manager` | no |
| `MAX_CPU_LIMIT_OVERCOMMIT` | string | The desired Maximum CPU Limits overcommitment factored into node recommendations.(e.g. 3=300% overcomitted) | `3` | no |
| `MAX_MEM_LIMIT_OVERCOMMIT` | string | The desired Maximum CPU Limits overcommitment factored into node recommendations.(e.g. 2=200% overcomitted) | `2` | no |
| `OPERATIONS_LOOKBACK_HOURS` | string | The time (in hours) to fetch and analyze cluster operations. | `24` | no |
| `OPERATIONS_STUCK_HOURS` | string | The amount of time (in hours) to declare an operation as stuck. | `2` | no |
| `NODE_HEALTH_LOOKBACK_HOURS` | string | The time (in hours) to look back for node pool events and compute operations when checking node health. | `24` | no |

## Secrets

| Name | Description | Required |
|---|---|---|
| `gcp_credentials` | GCP service account json used to authenticate with GCP APIs. | yes |

## Outputs

- `issues.json`
- `recommendations_issues.json`
- `version_support_issues.json`
- `cluster_health_issues.json`
- `region_quota_issues.json`
- `node_size_issues.json`
- `cluster_operations_issues.json`
- `node_pool_health_issues.json`

## How to invoke

### Production (RunWhen runner / worker)

The platform **runner** schedules work on a location **worker**. The worker
image (`rw-base-runtime`) executes Robot via `runrobot.sh` with
`RW_PATH_TO_ROBOT` set to the bound path under `/home/runwhen/collection/`.

- **Runbook**: `codebundles/gke-cluster-health/runbook.robot`

### Local development (devcontainer only)

`ro` is a dev-time wrapper in `codecollection-devtools` — not the enterprise runtime.

```bash
cd codebundles/gke-cluster-health
export GCP_PROJECT_ID=...
export CRITICAL_NAMESPACES=...
export MAX_CPU_LIMIT_OVERCOMMIT=...
export MAX_MEM_LIMIT_OVERCOMMIT=...
export OPERATIONS_LOOKBACK_HOURS=...
ro runbook.robot
```

### Standalone scripts (no Robot)


Set the input variables above, then run the matching script:

```bash
cd codebundles/gke-cluster-health
export GCP_PROJECT_ID=...
export CRITICAL_NAMESPACES=...
export MAX_CPU_LIMIT_OVERCOMMIT=...
bash check_gke_version_support.sh
bash cluster_health.sh
bash cluster_operations.sh
bash gcp_recommendations.sh
bash node_pool_health.sh
bash quota_check.sh
bash sa_check.sh
```

## Source files

- `runbook.robot` — orchestrates tools and raises issues
- `check_gke_version_support.sh` — Bash helper script `check_gke_version_support.sh`.
- `cluster_health.sh` — Bash helper script `cluster_health.sh`.
- `cluster_operations.sh` — Bash helper script `cluster_operations.sh`.
- `gcp_recommendations.sh` — Bash helper script `gcp_recommendations.sh`.
- `node_pool_health.sh` — Bash helper script `node_pool_health.sh`.
- `quota_check.sh` — Bash helper script `quota_check.sh`.
- `sa_check.sh` — Bash helper script `sa_check.sh`.
