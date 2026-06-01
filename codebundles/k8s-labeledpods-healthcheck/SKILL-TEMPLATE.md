---
name: k8s-labeledpods-healthcheck
kind: skill-template
description: This codebundle fetches the number of running pods with the set of provided labels, letting you measure the number... Use when triaging or monitoring Kubernetes, AKS, EKS workloads with skill templ...
runtime:
  monitor: sli.robot
  executor: worker
  entrypoint: /home/runwhen/robot-runtime/runrobot.sh
  base_image: rw-base-runtime
platforms: [Kubernetes, AKS, EKS, GKE, OpenShift]
resource_types: [pod]
access: read-only
---

# Kubernetes Labeled Pod Count

## Summary

This codebundle fetches the number of running pods with the set of provided labels, letting you measure the number of running pods.

See [README.md](README.md) for additional context.

## Monitor

This codebundle fetches the number of running pods with the set of provided labels, letting you measure the number of running pods.

- **Robot file**: `sli.robot`
- **Score range**: `0.0` (failing) to `1.0` (healthy)
- **Aggregation**: arithmetic mean of the sub-checks below
- **Recommended interval**: `180s`

### Sub-checks

#### Measure Number of Running Pods with Label in `${NAMESPACE}`

Counts the number of running pods with the configured labels.

- **Robot task name**: <code>Measure Number of Running Pods with Label in `${NAMESPACE}`</code>
- **Sub-metric name**: `labeled_pods_health`
- **Tags**: `access:read-only`, `Pods`, `Containers`, `Running`, `Status`, `Count`, `Health`, `data:config`
- **Reads**: `CONTEXT`, `KUBERNETES_DISTRIBUTION_BINARY`, `LABELS`, `NAMESPACE`


## Inputs

| Name | Type | Description | Default | Required |
|---|---|---|---|---|
| `NAMESPACE` | string | The name of the Kubernetes namespace to scope actions and searching to. Supports csv list of namespaces, or ALL. | — | yes |
| `CONTEXT` | string | Which Kubernetes context to operate within. | — | yes |
| `LABELS` | string | The metadata labels to use when selecting the objects to measure as running. | — | yes |
| `KUBERNETES_DISTRIBUTION_BINARY` | string | Which binary to use for Kubernetes CLI commands. | `kubectl` | no |

## Secrets

| Name | Description | Required |
|---|---|---|
| `kubeconfig` | The kubernetes kubeconfig yaml containing connection configuration used to connect to cluster(s). | yes |

## Outputs

- Monitor health score (`0.0`–`1.0`) pushed by `sli.robot`

## How to invoke

### Production (RunWhen runner / worker)

The platform **runner** schedules work on a location **worker**. The worker
image (`rw-base-runtime`) executes Robot via `runrobot.sh` with
`RW_PATH_TO_ROBOT` set to the bound path under `/home/runwhen/collection/`.

- **Monitor**: `codebundles/k8s-labeledpods-healthcheck/sli.robot`

### Local development (devcontainer only)

`ro` is a dev-time wrapper in `codecollection-devtools` — not the enterprise runtime.

```bash
cd codebundles/k8s-labeledpods-healthcheck
export NAMESPACE=...
export CONTEXT=...
export LABELS=...
export KUBERNETES_DISTRIBUTION_BINARY=...
ro sli.robot
```

### Standalone scripts (no Robot)


_No standalone shell scripts in this bundle._

## Source files

- `sli.robot` — monitor scoring (`sli.robot` runtime file)
