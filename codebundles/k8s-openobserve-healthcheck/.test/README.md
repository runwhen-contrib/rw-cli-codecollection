# k8s-openobserve-healthcheck - Tests

## Overview

This `.test/` directory provides infrastructure and Taskfile automation used to
validate the `k8s-openobserve-healthcheck` CodeBundle against a Kubernetes
cluster with RunWhen Local.

## Prerequisites

- A running Kubernetes cluster (local `kind`/`minikube`/k3s or a real cluster).
- `kubectl` configured with a kubeconfig file.
- Docker (to run the `runwhen-local` container).
- `task`, `yq`, `curl`, `ajv` on PATH.

## Quick start

1. Point `kubectl` at your test cluster.
2. Drop a kubeconfig file named `kubeconfig.secret` in this directory
   (used by RunWhen Local discovery).
3. `task build-infra` - creates the test namespace and OpenObserve resources.
4. `task default` - runs discovery and generates SLX/SLI/runbook configs under
   `output/workspaces/`.
5. `task clean` - removes the test objects and discovery output.

## Test resources

The `kubernetes/manifest.yaml` creates a namespace `test-openobserve-health`
containing:

- a Secret `openobserve-credentials` with `ROOT_USER_EMAIL` /
  `ROOT_USER_PASSWORD` (matching Helm defaults)
- a Service `openobserve` exposing port `5080`
- a Deployment `openobserve` (name matches the `openobserve` substring used by
  the generation rule)
- a PVC `openobserve-data`

The generation rule matches the Deployment by name, so discovery should produce
one SLX named after the workload `openobserve` in `test-openobserve-health`.

## Scenarios

The deployment declares `ZO_LOCAL_MODE=true` and a bound PVC. For failure
scenarios you can edit the manifest before applying:

- `replicas: 2` with a broken image -> replica/pod health issues.
- Unbind the PVC (`persistentVolumeReclaimPolicy` / delete the PV) -> PVC issues.
- Point the Service at a bogus port -> API health issues.