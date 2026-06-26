---
name: k8s-jenkins-healthcheck
kind: skill-template
description: This taskset collects information about perstistent volumes and persistent volume claims to. Use when triaging or monitoring Kubernetes, AKS, EKS workloads with skill template `k8s-jenkins-healthch...
runtime:
  runbook: runbook.robot
  executor: worker
  entrypoint: /home/runwhen/robot-runtime/runrobot.sh
  base_image: rw-base-runtime
platforms: [Kubernetes, AKS, EKS, GKE, OpenShift, Jenkins]
resource_types: [kubernetes_resource]
access: read-only
---

# Kubernetes Jenkins Healthcheck

## Summary

This taskset performs checks against its rest api to determine if there are any stuck jobs, which will result in raised issues if any are detected.

See [README.md](README.md) for additional context.

## Tools

### Query The Jenkins Kubernetes Workload HTTP Endpoint in Kubernetes StatefulSet `${STATEFULSET_NAME}`

Performs a curl within the jenkins statefulset kubernetes workload to determine if the pod is up and healthy, and can serve requests.

- **Robot task name**: <code>Query The Jenkins Kubernetes Workload HTTP Endpoint in Kubernetes StatefulSet `${STATEFULSET_NAME}`</code>
- **Robot file**: `runbook.robot`
- **Tags**: `access:read-only`, `HTTP`, `Curl`, `Web`, `Code`, `OK`, `Available`, `Jenkins`, `HTTP`, `Endpoint`, `API`, `data:config`
- **Reads**: `CONTEXT`, `JENKINS_SA_TOKEN`, `JENKINS_SA_USERNAME`, `KUBERNETES_DISTRIBUTION_BINARY`, `NAMESPACE`, `STATEFULSET_NAME`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Query For Stuck Jenkins Jobs in Kubernetes Statefulset Workload `${STATEFULSET_NAME}`

Performs a curl within the jenkins statefulset kubernetes workload to check for stuck jobs in the jenkins piepline queue.

- **Robot task name**: <code>Query For Stuck Jenkins Jobs in Kubernetes Statefulset Workload `${STATEFULSET_NAME}`</code>
- **Robot file**: `runbook.robot`
- **Tags**: `access:read-only`, `HTTP`, `Curl`, `Web`, `Code`, `OK`, `Available`, `Queue`, `Stuck`, `Jobs`, `Jenkins`, `data:config`
- **Reads**: `CONTEXT`, `JENKINS_SA_TOKEN`, `JENKINS_SA_USERNAME`, `KUBERNETES_DISTRIBUTION_BINARY`, `NAMESPACE`, `STATEFULSET_NAME`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


## Inputs

| Name | Type | Description | Default | Required |
|---|---|---|---|---|
| `KUBERNETES_DISTRIBUTION_BINARY` | string | Which binary to use for Kubernetes CLI commands. | `kubectl` | no |
| `CONTEXT` | string | Which Kubernetes context to operate within. | — | yes |
| `NAMESPACE` | string | The name of the namespace to search. | `` | yes |
| `STATEFULSET_NAME` | string | Used to target the resource for queries and filtering events. | — | yes |

## Secrets

| Name | Description | Required |
|---|---|---|
| `JENKINS_SA_USERNAME` | The username associated with the API token, typically the username. | yes |
| `JENKINS_SA_TOKEN` | The API token generated and managed by jenkins in the user configuration settings. | yes |

## Outputs

_See Robot run output and platform report artifacts._

## How to invoke

### Production (RunWhen runner / worker)

The platform **runner** schedules work on a location **worker**. The worker
image (`rw-base-runtime`) executes Robot via `runrobot.sh` with
`RW_PATH_TO_ROBOT` set to the bound path under `/home/runwhen/collection/`.

- **Runbook**: `codebundles/k8s-jenkins-healthcheck/runbook.robot`

### Local development (devcontainer only)

`ro` is a dev-time wrapper in `codecollection-devtools` — not the enterprise runtime.

```bash
cd codebundles/k8s-jenkins-healthcheck
export KUBERNETES_DISTRIBUTION_BINARY=...
export CONTEXT=...
export NAMESPACE=...
export STATEFULSET_NAME=...
ro runbook.robot
```

### Standalone scripts (no Robot)


_No standalone shell scripts in this bundle._

## Source files

- `runbook.robot` — orchestrates tools and raises issues
