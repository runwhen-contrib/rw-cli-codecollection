# Kubernetes SeaweedFS Storage Health Check

This CodeBundle validates SeaweedFS storage health in a Kubernetes namespace deployed via the official Helm chart or compatible operator installs. It inspects master Raft leadership, volume slot availability, disk capacity, filer connectivity, and optional S3 gateway operations so operators can detect misconfiguration before workloads fail.

## Overview

- **Resource discovery**: Maps SeaweedFS master, volume, filer, services, and PVCs; flags missing components or zero-ready workloads.
- **Workload health**: Checks StatefulSet/Deployment replica alignment, CrashLoopBackOff pods, pending scheduling, and recent Warning events.
- **Master cluster**: Queries `/cluster/status` and `/cluster/healthz` via in-cluster master HTTP APIs.
- **Volume slots**: Parses `/dir/status` topology for free slot exhaustion at cluster and nested topology nodes.
- **Disk capacity**: Reads volume server `/status` for free disk percentage and read-only volumes.
- **Writable layouts**: Detects zero-writable replication layouts and read-only volume IDs.
- **Connectivity**: Validates filer health endpoints and volume server registration in master topology.
- **S3 gateway**: When enabled, runs ListBuckets plus put/get/delete of a temporary probe object (read-write task).
- **Volume configuration audit**: Validates Helm-rendered commands, env, mounts, replication vs volume replica count, and peer wiring.
- **GC / compaction signals**: Reads Prometheus metrics for pick-for-write errors, crowded layouts, disk write failures, and delete-blocking read-only volumes.
- **Capacity projection**: Flags high slot/disk utilization and estimates time-to-full when a prior snapshot exists in `CODEBUNDLE_TEMP_DIR`.
- **Known version issues**: Matches `helm.sh/chart` version against a curated issue catalog.

## Configuration

### Required Variables

- `CONTEXT`: Kubernetes context for the target cluster.
- `NAMESPACE`: Namespace where SeaweedFS is deployed.

### Optional Variables

- `KUBERNETES_DISTRIBUTION_BINARY`: Kubernetes CLI binary (`kubectl` or `oc`; default: `kubectl`).
- `SEAWEEDFS_RELEASE_NAME`: Helm release name override for label-based discovery; leave empty for auto-discovery (default: empty).
- `SEAWEEDFS_MASTER_SERVICE`: Override master service DNS `host:port` (default: empty, auto-discovered via master pod exec).
- `SEAWEEDFS_FILER_SERVICE`: Override filer service DNS `host:port` (default: empty).
- `SEAWEEDFS_S3_ENDPOINT`: Override S3 endpoint URL (default: empty).
- `MIN_FREE_VOLUME_SLOTS`: Minimum free volume slots before raising an issue (default: `1`).
- `MIN_FREE_DISK_PERCENT`: Minimum free disk percentage on volume servers (default: `10`).
- `S3_PROBE_BUCKET`: Existing bucket for the S3 probe; a temporary object key is used (default: empty, auto-create when permitted).
- `CAPACITY_WARN_PERCENT`: Slot or disk utilization percent that triggers capacity projection warnings (default: `80`).
- `MIN_PROJECTION_HOURS`: Hours-until-full estimate that triggers slot exhaustion issues (default: `24`).
- `MAX_PICK_FOR_WRITE_ERRORS`: Master pick-for-write error counter threshold (default: `100`).
- `MAX_VOLUME_DISK_ERRORS`: Volume server disk write error counter threshold (default: `50`).
- `SEAWEEDFS_CHART`: Exact `helm.sh/chart` label (e.g. `seaweedfs-4.25.0`); auto-discovered when empty.

### Secrets

- `kubeconfig`: Kubernetes kubeconfig YAML with read access to the namespace.
- `seaweedfs_s3_credentials` (optional): JSON with `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` (or SeaweedFS IAM equivalents). Omit when S3 allows anonymous access or S3 is disabled.

## Tasks Overview

### List SeaweedFS Resources in Namespace

Builds a component map of SeaweedFS workloads, services, and PVCs. Raises issues when expected master/volume/filer components are missing or have zero ready replicas.

### Check SeaweedFS Workload Replica Health in Namespace

Verifies replica counts, CrashLoopBackOff pods, pending scheduling, and Warning events tied to SeaweedFS workloads.

### Check SeaweedFS Master Cluster Status in Namespace

Queries master HTTP APIs for health and Raft leader election status.

### Check SeaweedFS Volume Slot Availability in Namespace

Evaluates `/dir/status` free volume slots against `MIN_FREE_VOLUME_SLOTS`.

### Check SeaweedFS Volume Server Disk Capacity in Namespace

Inspects volume `/status` disk usage and read-only volume counts against `MIN_FREE_DISK_PERCENT`.

### Check SeaweedFS Writable Volume Layout in Namespace

Detects layouts with zero writables or read-only volume IDs in topology.

### Check SeaweedFS Filer and Component Connectivity in Namespace

Confirms filer `/healthz` or `/status` and that volume servers appear in master topology.

### Verify SeaweedFS S3 Gateway Operations in Namespace

Performs a minimal S3 probe when the filer S3 port is enabled; skips gracefully when S3 is disabled.

### Check SeaweedFS Volume Configuration in Namespace

Audits master/volume/filer workload commands, env vars, volume mounts, `defaultReplication`, and peer/replica alignment.

### Check SeaweedFS Garbage Collection and Compaction Signals in Namespace

Inspects master and volume `:9327/metrics` for pick-for-write errors, crowded layouts, heartbeat errors, and read-only volumes that block deletes.

### Check SeaweedFS Capacity Projection in Namespace

Reports slot and disk utilization headroom; compares against a prior snapshot in `CODEBUNDLE_TEMP_DIR` to estimate hours until slot exhaustion.

### Check SeaweedFS Known Version Issues in Namespace

Matches the installed chart version against `seaweedfs-known-issues.json` for upgrade cautions and version-specific behavior notes.

## Local testing

The `.test/` directory includes Terraform to deploy the [official SeaweedFS Helm chart](https://github.com/seaweedfs/seaweedfs/tree/master/k8s/charts/seaweedfs) into a dedicated namespace on an existing cluster (Kind/minikube). Prerequisites: `terraform`, `helm`, `kubectl`, and cluster admin access.

```bash
cd .test
task build-infra    # terraform apply (Helm release)
task clean          # terraform destroy
```

Use `task validate-generation-rules` to validate generation rule YAML against the RunWhen Local schema.

## Related bundles

- `k8s-pvc-healthcheck`: generic PVC binding and utilization (complements this bundle).
- `k8s-statefulset-healthcheck`: generic StatefulSet replica/probe checks.
- `k8s-loki-healthcheck`: similar in-cluster HTTP status API pattern.
