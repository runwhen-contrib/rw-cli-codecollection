# Kubernetes VictoriaMetrics Health Check

This CodeBundle validates [VictoriaMetrics](https://docs.victoriametrics.com/) workloads on Kubernetes: operator-style pod readiness, vmstorage PVC health, in-pod HTTP `/health` probes, optional vmselect cluster status JSON, and recent container log signatures for errors. Use it per namespace where VictoriaMetrics components run.

## Overview

- **Workload readiness**: Discovers Deployments, StatefulSets, DaemonSets, and pods that match common VictoriaMetrics labels (or an optional label selector) and reports CrashLoopBackOff, image pull failures, Pending pods, and rollout conditions that are not healthy.
- **Storage**: Flags VM-related PVCs that are not `Bound` or show binding or resize problems.
- **HTTP health**: Runs `kubectl exec` to hit `http://127.0.0.1:<port>/health` inside each running component pod using default ports (vmselect 8481, vminsert 8480, vmstorage 8482, single-node/vmagent 8429).
- **Cluster status**: When `VM_DEPLOYMENT_MODE` is `cluster` or `auto` and a vmselect pod exists, fetches cluster status JSON from vmselect and surfaces degraded signals when the response suggests unhealthy storage or nodes.
- **Logs**: Greps recent logs for ERROR, panic, or fatal patterns on VictoriaMetrics-labeled pods.
- **SLI**: A lightweight `sli.robot` scores namespace health from VM pod readiness and VM-related PVC binding (0–1).

## Configuration

### Required variables

- `CONTEXT`: Kubernetes context name to use.
- `NAMESPACE`: Namespace where VictoriaMetrics workloads are deployed.

### Optional variables

- `KUBERNETES_DISTRIBUTION_BINARY`: `kubectl`-compatible CLI (default: `kubectl`).
- `VM_LABEL_SELECTOR`: Optional Kubernetes label selector string (e.g. `app.kubernetes.io/instance=my-vm`) to narrow which pods and workloads are considered. If empty, the scripts use built-in VictoriaMetrics label and name heuristics.
- `VM_DEPLOYMENT_MODE`: `single`, `cluster`, or `auto` (default: `auto`). Controls whether the vmselect cluster status task runs (`single` skips it; `auto` runs it when a vmselect pod is found).

### Optional environment (scripts only)

These are read by bash scripts when set in the environment; they are not Robot imports:

- `VM_LOG_TAIL_LINES`: Tail length for log scan (default: `120`).
- `VM_LOG_SINCE`: `kubectl logs --since` window (default: `15m`).

### Secrets

- `kubeconfig`: Standard kubeconfig file for cluster access (same as other Kubernetes CodeBundles).

## Tasks overview

### Verify VictoriaMetrics workload pod readiness

Correlates VictoriaMetrics-tagged controllers and pods with Ready status, waiting reasons, and workload conditions.

### Check VictoriaMetrics storage PVCs

Evaluates PVCs likely tied to VictoriaMetrics (name patterns, labels, and StatefulSet volume claim templates) for phases other than `Bound` and for failing conditions.

### Probe VictoriaMetrics HTTP health endpoints

Uses `kubectl exec` and `wget`/`curl` inside each running pod to call `/health` on the documented default port for that component.

### Check VictoriaMetrics cluster status API (vmselect)

When applicable, queries vmselect for JSON cluster status (tries `/api/v1/status/cluster` on port 8481) and raises issues when the API is unreachable or the payload suggests degraded storage.

### Scan VictoriaMetrics recent logs for errors

Collects recent container logs and matches error/panic/fatal signatures to surface runtime failures.

### SLI (`sli.robot`)

Computes a 0–1 score from VM workload readiness and VM-related PVC binding; sub-metrics `vm_readiness` and `vm_pvc` are published for drill-down.
