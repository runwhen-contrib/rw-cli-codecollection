# VAST Data Tenant Storage Health

Monitor per-tenant and per-view storage health on VAST Data: volume capacity, quota utilization, QoS throttling, IO performance, and configuration policies that may limit users. Applies to all client types (Kubernetes PVCs backed by views, NFS clients, block volumes, S3 buckets).

## Overview

- **Tenant capacity**: Compares logical capacity, DRR, and quota utilization from `/api/prometheusmetrics/tenants`, `/api/prometheusmetrics/quotas`, and `/api/tenants/`.
- **View capacity**: Detects NFS exports and block views approaching capacity limits via `/api/prometheusmetrics/views`.
- **QoS saturation**: Evaluates tenant read/write IOPS and bandwidth against configured QoS ceilings.
- **QoS wait times**: Inspects `qos_wait_for_budget_time` and metadata IOPS limits for sustained throttling.
- **Tenant configuration**: Reviews export permissions, disabled tenants, and quota policies from VMS REST.
- **Latency anomalies**: Detects elevated read/write latency from tenant and view metrics.
- **Block volume health**: Monitors block volumes via `/api/prometheusmetrics/volumes` (VAST 5.4.3+).

Tenant and view names often appear in Kubernetes StorageClass parameters or PVC annotations when tracing from Kubernetes workloads. This bundle remains platform-native and queries VMS directly.

## Configuration

### Required Variables

- `VAST_VMS_ENDPOINT`: VMS REST API base URL (for example `https://vms.example.com`).
- `VAST_CLUSTER_NAME`: VAST cluster name used as an SLX qualifier and metric filter.
- `VAST_TENANT_NAME`: VAST tenant name used as the SLX qualifier and `X-Tenant-Name` scope for metrics.

### Optional Variables

- `TENANTS`: Tenant name or `All` for auto-discovery during generation (default: `All`).
- `CAPACITY_THRESHOLD`: Tenant/view capacity utilization percent threshold (default: `85`).
- `QOS_UTILIZATION_THRESHOLD`: Percent of QoS limit sustained that triggers a throttling issue (default: `90`).
- `LATENCY_THRESHOLD_MS`: Read/write latency in milliseconds above which to raise an issue (default: `10`).

### Secrets

- `vast_vms_credentials`: VMS API authentication credentials in JSON format:

```json
{
  "USERNAME": "vms-readonly-user",
  "PASSWORD": "secret"
}
```

Alternative token-based auth:

```json
{
  "API_TOKEN": "your-jwt-or-api-token"
}
```

A VMS manager user with the built-in read-only role is sufficient for Prometheus exporter endpoints.

## Tasks Overview

### Check Tenant Capacity Utilization

Compares tenant logical capacity and quota utilization against `CAPACITY_THRESHOLD`. Raises severity 2–3 issues when utilization exceeds the threshold.

### Check View Volume Capacity

Identifies views with high logical or quota utilization. Detects views at or near capacity that may block writes.

### Analyze Tenant IOPS and Bandwidth Against QoS Limits

Evaluates tenant read/write IOPS and bandwidth metrics versus QoS policy limits configured in VMS.

### Check QoS Wait Times and Throttling

Inspects view-level QoS wait time metrics and metadata IOPS limits to detect sustained throttling.

### Check User and Permission Configuration

Reviews tenant state, export policies, and quota flags that may restrict client access or capacity.

### Analyze Read Write Latency Anomalies

Detects elevated tenant and view read/write latency above `LATENCY_THRESHOLD_MS`.

### Check Block Volume Health

Monitors block volume IOPS and latency from `/api/prometheusmetrics/volumes`. Requires VAST Cluster 5.4.3+ with live monitoring enabled on volumes.

## SLI

The bundled SLI averages three binary dimensions into a 0–1 health score:

1. Capacity utilization below `CAPACITY_THRESHOLD`
2. No elevated QoS wait times
3. Read/write latency below `LATENCY_THRESHOLD_MS`

## Related CodeBundles

- `vast-cluster-health`: Cluster-level hardware and VMS state (complements this tenant/view bundle).
- `vast-k8s-csi-health`: Kubernetes CSI and PVC tracing.
- `k8s-pvc-healthcheck`: In-cluster PVC mount utilization.
- `gcp-bucket-health`: Similar capacity/access pattern for object storage on GCP.

## API References

- VAST Prometheus exporter: `/api/prometheusmetrics/tenants`, `/views`, `/quotas`, `/volumes`
- VMS REST: `/api/tenants/`, `/api/views/`, `/api/quotas/`
- Block volume metrics reference: https://kb.vastdata.com/documentation/docs/block-volume-metrics-reference
