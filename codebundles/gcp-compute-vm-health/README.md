# GCP Compute Engine VM Health

This CodeBundle monitors the health of **standalone** GCP Compute Engine VMs
(instances that are NOT part of an instance group, which are covered by
`gcp-compute-instancegroup-health`). It flags VMs that have been running too
long without a reboot, have pending or missing OS patches (via OS Config),
have disks filling up, have degraded network health, or show console/guest
issues.

It uses the `gcloud` command-line tool and the GCP OS Config API to interact
with the Compute Engine and OS Config services.

## Overview

- **Uptime / operational status**: detects VMs running longer than
  `UPTIME_WARNING_DAYS` since their last start (overdue reboot) and VMs that
  are not in a `RUNNING` state.
- **OS patch status**: uses the OS Config API (vulnerability reports and OS
  policy compliance) to flag VMs with affected/missing security patches.
- **Disk utilization**: flags disks above `DISK_USAGE_THRESHOLD` percent full
  (via the Ops Agent `agent.googleapis.com/disk/percent_used` metric) and
  disks in a degraded (non-`READY`) state.
- **Network health**: verifies internal/external IP assignment, network
  tag ↔ firewall-rule consistency, and visible packet-loss indicators.
- **Guest / serial console health**: scans serial console output for boot,
  kernel, guest-agent, and console error patterns.

## Configuration

### Required Variables

- `GCP_PROJECT_ID`: The GCP project ID hosting the VMs.

### Optional Variables

- `VM_NAME`: Name of the standalone VM to check, or `All` to scan every
  standalone VM in the project (default: `All`; auto-set by generation).
- `UPTIME_WARNING_DAYS`: Days a VM may run before a reboot is encouraged
  (default: `90`).
- `PATCH_WARNING_DAYS`: Days a missing/pending OS patch may go unremediated
  before alerting (default: `30`).
- `DISK_USAGE_THRESHOLD`: Disk usage percentage above which a disk is flagged
  as filling up (default: `85`).

### Secrets

- `gcp_credentials`: A GCP service account JSON key used with `gcloud`.
  The service account needs `roles/compute.viewer` and `roles/osconfig.viewer`
  (and, for disk/network usage metrics, permission to read Cloud Monitoring
  time series, e.g. `roles/monitoring.viewer`).

## Tasks Overview

### Discover Standalone GCP Compute VMs in Project `${GCP_PROJECT_ID}`
Lists standalone VM instances in the project (excluding instance-group
members) and dumps their configuration (name, zone, status, machine type).
Raises a severity 3 issue if no standalone VMs are found.

### Check VM Uptime and Operational Status for `${VM_NAME}`
Checks instance status and uptime, flagging VMs running longer than
`UPTIME_WARNING_DAYS` (severity 2) or in a degraded/non-running state
(severity 3).

### Check VM OS Patch Status via OS Config for `${VM_NAME}`
Inspects OS Config vulnerability reports and OS policy compliance, flagging
VMs with affected security patches (severity 2) or OS policy violations
(severity 3).

### Check VM Disk Utilization for `${VM_NAME}`
Flags disks above `DISK_USAGE_THRESHOLD` percent (severity 4) or in a degraded
state (severity 3).

### Check VM Network Health for `${VM_NAME}`
Flags missing network interfaces, tag/firewall mismatches, and reported
packet loss (severities 3).

### Check VM Guest and Serial Console Health for `${VM_NAME}`
Scans serial console output for boot/kernel/guest-agent/console error patterns
(severities 2–3).

## SLI

The bundled `sli.robot` produces a **0–1** health score as the arithmetic mean
of five binary dimensions, each pushed as a sub-metric:

- `uptime_status` — running and within `UPTIME_WARNING_DAYS`
- `patch_status` — no affected/missing patches
- `disk_status` — no disk over threshold / degraded
- `network_status` — no network health issues
- `console_status` — no guest/serial console errors

The aggregate is pushed as the primary metric (no `sub_name`) for alerting.

## Requirements

- `gcloud`, `jq`, and `curl` available in the execution environment
  (`rw-base-runtime`).
- Google Cloud APIs enabled: Compute Engine, OS Config, and (for utilization
  metrics) Cloud Monitoring.
- Service account permissions: `roles/compute.viewer`, `roles/osconfig.viewer`,
  and `roles/monitoring.viewer` for disk/network usage metrics.
