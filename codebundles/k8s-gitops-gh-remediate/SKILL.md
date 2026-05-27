---
name: k8s-gitops-gh-remediate
description: Provides a list of tasks that can remediate configuraiton issues with manifests in GitHub based GitOps repositories. Use when triaging or monitoring Kubernetes, AKS, EKS workloads with skill templa...
runtime:
  runbook: runbook.robot
  runner: ro
platforms: [Kubernetes, AKS, EKS, GKE, OpenShift, FluxCD, ArgoCD, GitHub]
resource_types: [kubernetes_resource]
access: read-write
---

# Kubernetes GitOps GitHub Remediation

## Summary

This codebundle provides a suite of tasks aimed at remediating configuration issues related to Kubernetes deployments managed in github repositories.

See [README.md](README.md) for additional context.

## Tools

### Remediate Readiness and Liveness Probe GitOps Manifests in Namespace `${NAMESPACE}`

Fixes misconfigured readiness or liveness probe configurations for pods in a namespace that are managed in a GitHub GitOps repository

- **Robot task name**: <code>Remediate Readiness and Liveness Probe GitOps Manifests in Namespace `${NAMESPACE}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `update_github_manifests.sh`
- **Tags**: `access:read-write`, `readiness`, `liveness`, `probe`, `remediate`, `gitops`, `github`, `data:config`
- **Reads**: `NAMESPACE`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Increase ResourceQuota Limit for Namespace `${NAMESPACE}` in GitHub GitOps Repository

Looks for a resourcequota object in the namespace and increases it if applicable, and if it is managed in a GitHub GitOps repository

- **Robot task name**: <code>Increase ResourceQuota Limit for Namespace `${NAMESPACE}` in GitHub GitOps Repository</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `update_github_manifests.sh`
- **Tags**: `access:read-write`, `resourcequota`, `quota`, `namespace`, `remediate`, `github`, `gitops`, `data:config`
- **Reads**: `NAMESPACE`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Adjust Pod Resources to Match VPA Recommendation in `${NAMESPACE}`

Queries the namespace for any Vertical Pod Autoscaler resource recommendations and applies them to GitOps GitHub controlled manifests.

- **Robot task name**: <code>Adjust Pod Resources to Match VPA Recommendation in `${NAMESPACE}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `update_github_manifests.sh`
- **Tags**: `access:read-write`, `recommendation`, `resources`, `utilization`, `gitops`, `github`, `pods`, `cpu`, `memory`, `allocation`, `vpa`, `data:config`
- **Reads**: `NAMESPACE`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Expand Persistent Volume Claims in Namespace `${NAMESPACE}`

Checks the disk utilization for all PVCs and updates the GitOps manifest for any that are highly utilized.

- **Robot task name**: <code>Expand Persistent Volume Claims in Namespace `${NAMESPACE}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `update_github_manifests.sh`
- **Tags**: `access:read-write`, `recommendation`, `pv`, `pvc`, `utilization`, `gitops`, `github`, `persistentvolumeclaim`, `persistentvolume`, `storage`, `capacity`, `data:config`
- **Reads**: `NAMESPACE`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


## Inputs

| Name | Type | Description | Default | Required |
|---|---|---|---|---|
| `NAMESPACE` | string | The name of the Kubernetes namespace to scope actions and searching to. | — | yes |
| `CONTEXT` | string | Which Kubernetes context to operate within. | `''` | no |
| `KUBERNETES_DISTRIBUTION_BINARY` | string | Which binary to use for Kubernetes CLI commands. | `kubectl` | no |

## Secrets

_No secrets imported in Robot source._

## Outputs

_See Robot run output and platform report artifacts._

## How to invoke

### Preferred: Robot Framework runner (`ro`)

```bash
cd codebundles/k8s-gitops-gh-remediate
export NAMESPACE=...
export CONTEXT=...
export KUBERNETES_DISTRIBUTION_BINARY=...
ro runbook.robot
```

### Standalone scripts (no Robot)


Set the input variables above, then run the matching script:

```bash
cd codebundles/k8s-gitops-gh-remediate
export NAMESPACE=...
export CONTEXT=...
export KUBERNETES_DISTRIBUTION_BINARY=...
bash pvc_utilization_check.sh
bash resource_quota_check.sh
bash update_github_manifests.sh
bash validate_all_probes.sh
bash vpa_recommendations.sh
```

## Source files

- `runbook.robot` — orchestrates tools and raises issues
- `pvc_utilization_check.sh` — Bash helper script `pvc_utilization_check.sh`.
- `resource_quota_check.sh` — Bash helper script `resource_quota_check.sh`.
- `update_github_manifests.sh` — Bash helper script `update_github_manifests.sh`.
- `validate_all_probes.sh` — Bash helper script `validate_all_probes.sh`.
- `vpa_recommendations.sh` — Bash helper script `vpa_recommendations.sh`.
