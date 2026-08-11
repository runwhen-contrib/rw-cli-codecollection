---
name: gcp-compute-instancegroup-health
kind: skill-template
description: Identify health, capacity, security, and configuration problems in GCP Compute Engine instance groups (managed and unmanaged). Use when triaging or monitoring GCP, Compute Engine, Instance Group workloads with skill template `gcp-compute-instancegroup-health`.
runtime:
  runbook: runbook.robot
  monitor: sli.robot
  executor: worker
  entrypoint: /home/runwhen/robot-runtime/runrobot.sh
  base_image: rw-base-runtime
platforms: [GCP, Compute Engine, Instance Groups]
resource_types: [gcp_compute_instance_group, gcp_compute_instance_group_manager]
access: read-only
---

# GCP Compute Engine Instance Group Health

## Summary

Monitors GCP Compute Engine instance groups (managed and unmanaged) at the
group scope: member instance health, autoscaling and capacity, OS patch
compliance, and CPU utilization.

Every tool is scoped to the single instance group named by
`INSTANCE_GROUP_NAME`, which is the group the SLX represents. There is no
project-scoped inventory or rollup tool, because it would repeat the same
findings on every instance group SLX in the project.

See [README.md](README.md) for additional context.

## Tools

### Check Instance Group Member Health for `${INSTANCE_GROUP_NAME}`

Checks that all members are RUNNING/healthy, flagging stopped/degraded/recreating instances.

- **Robot task name**: <code>Check Instance Group Member Health for `${INSTANCE_GROUP_NAME}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `check_group_member_health.sh`
- **Tags**: `gcloud`, `gcp`, `instancegroup`, `access:read-only`, `data:metrics`
- **Reads**: `GCP_PROJECT_ID`, `INSTANCE_GROUP_NAME`
- **Writes**: `group_member_health_issues.json`
- **Issues raised**: severity 3 per recycling member, 2 per stopped/terminated member

### Check Instance Group Autoscaling and Capacity for `${INSTANCE_GROUP_NAME}`

Verifies current size vs target and flags autoscaler failures or inability to scale.

- **Robot task name**: <code>Check Instance Group Autoscaling and Capacity for `${INSTANCE_GROUP_NAME}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `check_autoscaling.sh`
- **Tags**: `gcloud`, `gcp`, `instancegroup`, `access:read-only`, `data:metrics`
- **Reads**: `GCP_PROJECT_ID`, `INSTANCE_GROUP_NAME`
- **Writes**: `group_autoscaling_issues.json`
- **Issues raised**: severity 4 (cannot scale / at max), 3 (autoscaler in ERROR / below min), 2 (target size 0 with no autoscaler)

### Check Instance Group OS Patch Compliance for `${INSTANCE_GROUP_NAME}`

Checks OS Config patch compliance across members beyond `PATCH_WARNING_DAYS`.

- **Robot task name**: <code>Check Instance Group OS Patch Compliance for `${INSTANCE_GROUP_NAME}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `check_group_patch_status.sh`
- **Tags**: `gcloud`, `gcp`, `instancegroup`, `osconfig`, `access:read-only`, `data:logs-config`
- **Reads**: `GCP_PROJECT_ID`, `INSTANCE_GROUP_NAME`, `PATCH_WARNING_DAYS`
- **Writes**: `group_patch_issues.json`
- **Issues raised**: severity 3 per member with a failed or timed-out patch, 4 (informational) when no patch history is available

### Check Instance Group Utilization for `${INSTANCE_GROUP_NAME}`

Checks average CPU utilization via Cloud Monitoring, flagging over/under-utilization.

- **Robot task name**: <code>Check Instance Group Utilization for `${INSTANCE_GROUP_NAME}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `check_group_utilization.sh`
- **Tags**: `gcloud`, `gcp`, `instancegroup`, `monitoring`, `access:read-only`, `data:metrics`
- **Reads**: `GCP_PROJECT_ID`, `INSTANCE_GROUP_NAME`, `UTILIZATION_LOW_THRESHOLD`, `UTILIZATION_HIGH_THRESHOLD`
- **Writes**: `group_utilization_issues.json`
- **Issues raised**: severity 4 (over-utilized), 3 (under-utilized)

## Monitor

Group-scoped 0-1 health score averaged across four dimensions.

- **Robot file**: `sli.robot`
- **Score range**: `0` (failing) to `1` (healthy)
- **Aggregation**: mean of the sub-checks below
- **Recommended interval**: `180s`

### Sub-checks

#### Score Instance Group Member Health for `${INSTANCE_GROUP_NAME}`

Scores 1 if no member is degraded/stopped/recreating.

- **Sub-metric names**: `member_health`
- **Tags**: `gcloud`, `gcp`, `instancegroup`, `access:read-only`, `data:metrics`
- **Pass condition**: `group_member_health_issues.json` has no severity 1-3 issue (severity 1 is most severe; severity 4 is informational)

#### Score Instance Group Autoscaling and Capacity for `${INSTANCE_GROUP_NAME}`

Scores 1 if the group can scale to meet demand within bounds.

- **Sub-metric names**: `autoscaling`
- **Tags**: `gcloud`, `gcp`, `instancegroup`, `access:read-only`, `data:metrics`
- **Pass condition**: `group_autoscaling_issues.json` has no severity 1-3 issue

#### Score Instance Group Patch Compliance for `${INSTANCE_GROUP_NAME}`

Scores 1 if all members have current OS patches.

- **Sub-metric names**: `patch_compliance`
- **Tags**: `gcloud`, `gcp`, `instancegroup`, `osconfig`, `access:read-only`, `data:logs-config`
- **Pass condition**: `group_patch_issues.json` has no severity 1-3 issue

#### Score Instance Group Utilization for `${INSTANCE_GROUP_NAME}`

Scores 1 if average CPU utilization is within bounds.

- **Sub-metric names**: `utilization`
- **Tags**: `gcloud`, `gcp`, `instancegroup`, `monitoring`, `access:read-only`, `data:metrics`
- **Pass condition**: `group_utilization_issues.json` has no severity 1-3 issue

## Inputs

| Name | Type | Description | Default | Required |
|---|---|---|---|---|
| `GCP_PROJECT_ID` | string | The GCP project ID hosting the instance groups. | — | yes |
| `INSTANCE_GROUP_NAME` | string | Name of the instance group to check; `All` inspects every group. | `All` | no |
| `PATCH_WARNING_DAYS` | string | Days a missing OS patch may go unremediated before alerting. | `30` | no |
| `UTILIZATION_LOW_THRESHOLD` | string | CPU % below which a group is under-utilized. | `5` | no |
| `UTILIZATION_HIGH_THRESHOLD` | string | CPU % above which a group is over-utilized. | `90` | no |

## Secrets

| Name | Description | Required |
|---|---|---|
| `gcp_credentials` | GCP service account JSON key used to authenticate with GCP APIs. | yes |

## Outputs

- Group-scoped monitor health score (`0`-`1`) pushed by `sli.robot`
- Sub-metrics per health dimension (`member_health`, `autoscaling`, `patch_compliance`, `utilization`)
- `group_member_health_issues.json`
- `group_autoscaling_issues.json`
- `group_patch_issues.json`
- `group_utilization_issues.json`

## How to invoke

### Production (RunWhen runner / worker)

The platform **runner** schedules work on a location **worker**. The worker image
(`rw-base-runtime`) executes Robot via `runrobot.sh` with `RW_PATH_TO_ROBOT` set
to the bound path under `/home/runwhen/collection/`.

- **Runbook**: `codebundles/gcp-compute-instancegroup-health/runbook.robot`
- **Monitor**: `codebundles/gcp-compute-instancegroup-health/sli.robot`

### Local development (devcontainer only)

`ro` is a dev-time wrapper in `codecollection-devtools` — not the enterprise runtime.

```bash
cd codebundles/gcp-compute-instancegroup-health
export GCP_PROJECT_ID=...
export INSTANCE_GROUP_NAME=...
ro runbook.robot
```

### Standalone scripts (no Robot)

Set the input variables above, then run the matching script:

```bash
cd codebundles/gcp-compute-instancegroup-health
export GCP_PROJECT_ID=...
export INSTANCE_GROUP_NAME=ig-healthy
bash check_group_member_health.sh
bash check_autoscaling.sh
bash check_group_patch_status.sh
bash check_group_utilization.sh
```

## Source files

- `runbook.robot` — orchestrates tools and raises issues
- `sli.robot` — group-scoped multi-dimensional monitor scoring
- `check_group_member_health.sh` — detects degraded/stopped/recreating members
- `check_autoscaling.sh` — verifies autoscaling and capacity
- `check_group_patch_status.sh` — OS Config patch compliance
- `check_group_utilization.sh` — Cloud Monitoring CPU utilization
