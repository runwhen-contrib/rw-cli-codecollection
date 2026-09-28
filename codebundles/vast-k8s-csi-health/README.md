# VAST Data Kubernetes CSI Health

Monitor the VAST CSI driver in Kubernetes and trace application storage from PVC/PV through to VAST views. Detects CSI driver failures, NFS transport congestion, mount issues, and optionally correlates in-cluster storage symptoms with VAST backend health.

## Overview

- **CSI driver health**: Controller and node pod readiness, CrashLoopBackOff, and restart counts in the CSI install namespace
- **CSI metrics**: RPC failure rates and slow operations from Prometheus `/metrics` on ports 9090 (node) and 9091 (controller)
- **NFS transport**: `csi_node_nfs_xprt_*` congestion, unhealthy VIPs, and pending request thresholds
- **PVC tracing**: Maps PVC → PV → StorageClass to VAST view path, tenant, and VIP identifiers
- **Workload mounts**: Pod mount failures, warning events, and VolumeAttachment issues for VAST volumes
- **StorageClass validation**: Endpoint, view policy, tenant, mount options, and expansion settings
- **VMS correlation**: Optional cross-reference of failing PVCs with VMS tenant capacity/QoS metrics

## Configuration

### Required Variables

- `CONTEXT`: Kubernetes context name
- `NAMESPACE`: Kubernetes namespace for workload PVC tracing and mount checks

### Optional Variables

- `CSI_NAMESPACE`: Namespace where the VAST CSI driver is installed (default: `vast-csi`)
- `KUBERNETES_DISTRIBUTION_BINARY`: Kubernetes CLI binary (default: `kubectl`)
- `VAST_VMS_ENDPOINT`: Optional VMS REST base URL for backend correlation (e.g. `https://vms.example.com`)
- `VAST_CLUSTER_NAME`: Optional VAST cluster name used in correlation titles
- `XPRT_PENDING_THRESHOLD`: `csi_node_nfs_xprt_pending_requests` count that triggers an issue (default: `100`)
- `RPC_ERROR_RATE_THRESHOLD`: CSI RPC error rate percent threshold (default: `5`)

### Secrets

- `kubeconfig`: Standard kubeconfig YAML for Kubernetes cluster access
- `vast_vms_credentials` (optional): JSON object with `USERNAME` and `PASSWORD`, or `API_TOKEN`, for VMS API access when `VAST_VMS_ENDPOINT` is set

## Tasks Overview

### Check VAST CSI Driver Pod Health
Verifies CSI controller and node pods are Running/Ready; detects CrashLoopBackOff, not-Ready pods, high restarts, and replica gaps.

### Check CSI Node and Controller Metrics for RPC Failures
Scrapes `/metrics` from CSI pods or headless metrics Services; flags elevated `csi_plugin_operations` error rates and slow RPC durations.

### Check NFS Transport Health on CSI Nodes
Analyzes `csi_node_nfs_xprt_unhealthy`, `csi_node_nfs_xprt_congested_state`, and pending request metrics for VIP connectivity and congestion.

### Trace Kubernetes PVCs to VAST Views
Produces a trace report linking each VAST-backed PVC to PV volumeHandle, StorageClass parameters, view path, tenant, and VIP.

### Check End-to-End Pod Mount Health
Finds pods using VAST PVCs that are not Ready, plus mount-related warning events and VolumeAttachment failures.

### Check VAST StorageClass Configuration
Validates VAST StorageClass parameters (endpoint, view policy, tenant, mount options) for misconfigurations.

### Correlate Kubernetes Storage Events with VAST Tenant Metrics
When `VAST_VMS_ENDPOINT` is configured, fetches `/api/prometheusmetrics/tenants` and correlates unbound or failing PVCs with tenant signals. Skips gracefully with an informational report when the endpoint is unset.

## Platform Notes

- VAST CSI metrics are exposed at `GET /metrics` on node port **9090** and controller port **9091** (override via Helm `metrics.port`)
- Enable metrics in the Helm chart: `metrics.enabled=true`
- StorageClass provisioner ID: `csi.vastdata.com`
- See [VAST CSI metrics documentation](https://kb.vastdata.com/documentation/docs/exporting-vast-csi-driver-metrics-to-prometheus)

## Related Bundles

- `k8s-pvc-healthcheck`: General PVC health; this bundle adds VAST-specific CSI metrics and tracing
- `vast-tenant-storage-health`: Backend tenant QoS and capacity (complements this Kubernetes front-end view)
