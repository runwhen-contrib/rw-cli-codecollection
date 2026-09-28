# VAST Data Cluster Health

Monitor VAST Data cluster-wide health via the VMS REST API and Prometheus exporter endpoints. Detects degraded cluster state, capacity exhaustion, hardware failures on CNodes/DNodes, and cluster-level performance bottlenecks that affect all tenants and clients (Kubernetes, NFS, block, S3).

## Overview

- **VMS cluster state**: Queries `/api/prometheusmetrics/vms_state`, `/health/`, and `/api/clusters/` for DEGRADED vs CLUSTERED/ONLINE state
- **Capacity utilization**: Evaluates physical and logical capacity from cluster REST and Prometheus metrics against configurable thresholds
- **Node hardware health**: Inspects CNode/DNode REST state and SSD/SCM indicators from `/api/prometheusmetrics/devices`
- **Degraded components**: Surfaces active alarms, degraded boxes, and offline nodes
- **Protocol performance**: Samples cluster-wide IOPS and latency metrics for NFS, block, and S3 from Prometheus exporters
- **Replication and protection**: Checks replication streams, protection groups, and auxiliary/snapshot capacity pressure

## Configuration

### Required Variables

- `VAST_VMS_ENDPOINT`: VMS REST API base URL (e.g. `https://vms.example.com`)
- `VAST_CLUSTER_NAME`: VAST cluster display name for scoping and issue titles

### Optional Variables

- `RESOURCES`: Cluster name(s) or `All` for auto-discovery via VMS `/api/clusters/` (default: `All`)
- `CAPACITY_THRESHOLD`: Physical/logical capacity utilization percent that triggers a warning issue (default: `85`)
- `CRITICAL_CAPACITY_THRESHOLD`: Critical capacity threshold percent (default: `95`)

### Secrets

- `vast_vms_credentials`: VMS API authentication credentials as JSON:
  - `USERNAME` and `PASSWORD` for basic auth, or
  - `API_TOKEN` for bearer token auth (when supported by your VMS version)

## Tasks Overview

### Check VMS Cluster Health Status for Cluster

Queries `/api/prometheusmetrics/vms_state` and VMS cluster status to detect DEGRADED (0) vs CLUSTERED (1) state and cluster-level health regressions.

### Check Cluster Capacity Utilization for Cluster

Evaluates physical and logical capacity utilization from `/api/clusters/` and Prometheus capacity metrics; raises issues when usage exceeds `CAPACITY_THRESHOLD` or `CRITICAL_CAPACITY_THRESHOLD`.

### Check CNode and DNode Hardware Health for Cluster

Inspects CNode/DNode state from REST APIs and SSD/SCM health from Prometheus `/api/prometheusmetrics/devices`.

### Check Cluster Degraded Components and Active Alerts for Cluster

Lists degraded boxes, offline nodes, and active VMS alarms from `/api/prometheusmetrics/alarms` and related REST endpoints.

### Analyze Cluster Protocol Performance for Cluster

Reviews cluster-wide IOPS and latency by storage protocol (NFS, block, S3) from Prometheus base metrics to detect IO stalls or abnormal drops.

### Check Replication and Protection Group Status for Cluster

Verifies replication links, protection groups, and snapshot/auxiliary capacity pressure from REST and `/api/prometheusmetrics/replications`.

## SLI

The bundled `sli.robot` produces a 0–1 health score from five binary dimensions:

1. VMS clustered state
2. Capacity headroom
3. Node hardware health
4. Active alarm clearance
5. Replication health

## Platform Notes

- Prometheus metrics are scraped directly from VMS REST paths such as `/api/prometheusmetrics/vms_state` and `/api/prometheusmetrics/all` — no local Prometheus server is required.
- Some endpoints (`/health/`, `/api/prometheusmetrics/replications`, `/api/protectiongroups/`) are unavailable on older VAST versions; tasks degrade gracefully and skip optional checks.
- API reference: [Exporting Metrics to Prometheus](https://kb.vastdata.com/documentation/docs/exporting-metrics-to-prometheus)
- VMS REST docs: `{VAST_VMS_ENDPOINT}/docs`

## Testing

Use mock fixtures under `.test/fixtures/` when a live VAST cluster is unavailable:

```bash
cd codebundles/vast-cluster-health/.test
task
```
