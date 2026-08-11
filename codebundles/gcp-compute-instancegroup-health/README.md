# GCP Compute Engine Instance Group Health

This CodeBundle monitors the health of GCP Compute Engine instance groups
(managed and unmanaged) at the group scope. It produces one SLX per instance
group rather than per member VM, checking that all member instances are
healthy/running, that autoscaling is functioning, and that patch compliance and
utilization across the group are acceptable.

Every task is scoped to the single instance group named by
`INSTANCE_GROUP_NAME`, which is the group the SLX represents. The bundle
deliberately carries no project-wide task: a project-scoped inventory or rollup
would report the same findings on every instance group SLX in the project.

## Overview

This bundle monitors:

- **Member instance health**: Verifies all member instances are in a
  RUNNING/healthy state, flagging stopped, degraded, or re-creating instances
  (for example nodes recycling in a managed group).
- **Autoscaling and capacity**: For managed instance groups, verifies current
  size vs. target and flags autoscaler failures, unschedulable events, or
  groups unable to scale to meet demand.
- **OS patch compliance**: Uses GCP OS Config to check patch compliance across
  group members, flagging groups with pending or missing security patches
  beyond `PATCH_WARNING_DAYS`.
- **Utilization**: Checks average CPU/utilization across group members via
  Cloud Monitoring, flagging groups that are consistently over- or
  under-utilized (scaling risk or wasted capacity).

## Configuration

### Required Variables

- `GCP_PROJECT_ID`: The GCP project ID hosting the instance groups being
  monitored.

### Optional Variables

- `INSTANCE_GROUP_NAME`: Name of the instance group to check. Set to `All` to
  inspect every instance group in the project (default: `All`). When generated
  per-instance-group SLX, this is auto-set to the group name.
- `PATCH_WARNING_DAYS`: Days a missing/pending OS patch in the group may go
  unremediated before alerting (default: `30`).
- `UTILIZATION_LOW_THRESHOLD`: Average CPU utilization percentage below which a
  group is considered under-utilized/wasted capacity (default: `5`).
- `UTILIZATION_HIGH_THRESHOLD`: Average CPU utilization percentage above which a
  group is considered over-utilized and a scaling risk (default: `90`).

### Secrets

- `gcp_credentials`: GCP service account JSON key used to authenticate with GCP
  APIs. Format is the standard GCP service account JSON object
  (`type`, `project_id`, `private_key_id`, `private_key`, `client_email`,
  `client_id`, `auth_uri`, `token_uri`).

### Required Permissions

The service account needs the following roles on the monitored project:

- `roles/compute.viewer` — list/describe instance groups and members
- `roles/osconfig.viewer` — read OS patch compliance
- `roles/monitoring.viewer` — read Cloud Monitoring utilization metrics

## Tasks Overview

### Check Instance Group Member Health for `${INSTANCE_GROUP_NAME}`

Checks that all member instances of the group are in RUNNING/healthy state,
flagging stopped, degraded, or re-creating instances. Detects severity 2-3
member health issues.

### Check Instance Group Autoscaling and Capacity for `${INSTANCE_GROUP_NAME}`

For managed instance groups with autoscaling, verifies current size vs. target
and flags groups unable to scale to meet demand. The autoscaler is read from the
group description, which carries the attached autoscaler and its policy; an
autoscaler reporting status `ERROR` is flagged as severity 3, because the group
cannot scale while it is failing. A managed group with no autoscaler and a
target size of 0 is flagged as severity 2, because it holds no capacity at all.
Detects severity 2-4 capacity issues.

### Check Instance Group OS Patch Compliance for `${INSTANCE_GROUP_NAME}`

Uses GCP OS Config to check patch compliance across group members when
available, flagging members whose patch job failed or timed out more than
`PATCH_WARNING_DAYS` ago. Detects severity 3 patch compliance issues. When the
project does not use OS Config, the missing patch history is reported as a
severity 4 (informational) finding: it is a gap in coverage, so it does not by
itself mark the group unhealthy.

### Check Instance Group Utilization for `${INSTANCE_GROUP_NAME}`

Checks average CPU/disk utilization across group members via Cloud Monitoring,
flagging groups that are consistently over- or under-utilized. Detects
severity 3-4 utilization issues.

## SLI

The SLI produces a 0-1 health score calculated as the average of four binary
dimensions, each pushed as a sub-metric for dashboard drill-down:

- **Member health** — no degraded/stopped/recreating group members
- **Autoscaling** — the group can scale to meet demand within its bounds
- **Patch compliance** — no members with pending/missing security patches
- **Utilization** — average CPU utilization is within configured bounds

The final aggregate is pushed without a `sub_name` and drives alerting.

Each dimension scores 1 only when its check completed and recorded no issue of
severity 1-3 (severity 1 is the most severe; severity 4 is informational). A
check that fails to run records its own severity 2 issue, so a broken check
scores 0 and is never reported as healthy.

## Requirements

The CodeBundle requires the `gcloud` CLI and `jq` to be available in the
execution environment. See the Design Spec and API reference at
https://cloud.google.com/compute/docs/reference/rest/v1/instanceGroups.
