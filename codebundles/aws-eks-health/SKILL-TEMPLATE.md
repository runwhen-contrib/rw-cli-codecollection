---
name: aws-eks-health
kind: skill-template
description: Checks the health status of an EKS cluster including node groups, add-ons, and Fargate profiles. Use when triaging or monitoring AWS, EKS, Fargate workloads with skill template `aws-eks-health`.
runtime:
  runbook: runbook.robot
  runner: ro
platforms: [AWS, EKS, Fargate]
resource_types: [eks_cluster]
access: read-only
---

# AWS EKS Cluster Health

## Summary

Comprehensive health checks for Amazon EKS clusters in a given AWS region.

See [README.md](README.md) for additional context.

## Tools

### Check EKS Cluster `${EKS_CLUSTER_NAME}` Health in Account `${AWS_ACCOUNT_NAME}` Region `${AWS_REGION}`

Checks overall EKS cluster health including status, configuration, add-ons, and node group summary.

- **Robot task name**: <code>Check EKS Cluster `${EKS_CLUSTER_NAME}` Health in Account `${AWS_ACCOUNT_NAME}` Region `${AWS_REGION}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `check_eks_cluster_health.sh`
- **Tags**: `EKS`, `Cluster`, `Health`, `AWS`, `Kubernetes`, `access:read-only`, `data:config`
- **Reads**: `AWS_REGION`, `EKS_CLUSTER_NAME`
- **Writes**: `eks_cluster_health.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Check Fargate Profile Health for EKS Cluster `${EKS_CLUSTER_NAME}` in Account `${AWS_ACCOUNT_NAME}` Region `${AWS_REGION}`

Checks the health status of all Fargate profiles for the EKS cluster.

- **Robot task name**: <code>Check Fargate Profile Health for EKS Cluster `${EKS_CLUSTER_NAME}` in Account `${AWS_ACCOUNT_NAME}` Region `${AWS_REGION}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `check_eks_fargate_cluster_health_status.sh`
- **Tags**: `EKS`, `Fargate`, `Cluster`, `Health`, `AWS`, `Kubernetes`, `Pods`, `access:read-only`, `data:config`
- **Reads**: `AWS_REGION`, `EKS_CLUSTER_NAME`
- **Writes**: `eks_fargate_health.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Check Kubernetes Version Support for EKS Cluster `${EKS_CLUSTER_NAME}` in Account `${AWS_ACCOUNT_NAME}` Region `${AWS_REGION}`

Checks whether the EKS cluster is running a deprecated or extended-support Kubernetes version and estimates cost impact. AWS charges a $0.60/hr/cluster surcharge for versions in extended support (7x standard cost).

- **Robot task name**: <code>Check Kubernetes Version Support for EKS Cluster `${EKS_CLUSTER_NAME}` in Account `${AWS_ACCOUNT_NAME}` Region `${AWS_REGION}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `check_eks_version_support.sh`
- **Tags**: `EKS`, `Version`, `Deprecation`, `Cost`, `AWS`, `Kubernetes`, `access:read-only`, `data:config`
- **Reads**: `AWS_REGION`, `EKS_CLUSTER_NAME`
- **Writes**: `eks_version_support.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Check Node Group Health for EKS Cluster `${EKS_CLUSTER_NAME}` in Account `${AWS_ACCOUNT_NAME}` Region `${AWS_REGION}`

Checks the health and scaling status of all managed node groups for the EKS cluster.

- **Robot task name**: <code>Check Node Group Health for EKS Cluster `${EKS_CLUSTER_NAME}` in Account `${AWS_ACCOUNT_NAME}` Region `${AWS_REGION}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `check_eks_nodegroup_health.sh`
- **Tags**: `AWS`, `EKS`, `Node`, `Health`, `Kubernetes`, `Nodes`, `access:read-only`, `data:config`
- **Reads**: `AWS_REGION`, `EKS_CLUSTER_NAME`
- **Writes**: `eks_nodegroup_health.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


## Inputs

| Name | Type | Description | Default | Required |
|---|---|---|---|---|
| `AWS_REGION` | string | AWS Region | — | yes |
| `EKS_CLUSTER_NAME` | string | The name of the EKS cluster to check. | — | yes |
| `AWS_ACCOUNT_NAME` | string | AWS account name or alias for display purposes. | `Unknown` | no |

## Secrets

| Name | Description | Required |
|---|---|---|
| `aws_credentials` | AWS credentials from the workspace (from aws-auth block; e.g. aws:access_key@cli, aws:irsa@cli). | yes |

## Outputs

- `eks_cluster_health.json`
- `eks_fargate_health.json`
- `eks_version_support.json`
- `eks_nodegroup_health.json`

## How to invoke

### Preferred: Robot Framework runner (`ro`)

```bash
cd codebundles/aws-eks-health
export AWS_REGION=...
export EKS_CLUSTER_NAME=...
export AWS_ACCOUNT_NAME=...
ro runbook.robot
```

### Standalone scripts (no Robot)


Set the input variables above, then run the matching script:

```bash
cd codebundles/aws-eks-health
export AWS_REGION=...
export EKS_CLUSTER_NAME=...
export AWS_ACCOUNT_NAME=...
bash check_eks_cluster_health.sh
bash check_eks_fargate_cluster_health_status.sh
bash check_eks_nodegroup_health.sh
bash check_eks_version_support.sh
```

## Source files

- `runbook.robot` — orchestrates tools and raises issues
- `check_eks_cluster_health.sh` — Bash helper script `check_eks_cluster_health.sh`.
- `check_eks_fargate_cluster_health_status.sh` — Bash helper script `check_eks_fargate_cluster_health_status.sh`.
- `check_eks_nodegroup_health.sh` — Bash helper script `check_eks_nodegroup_health.sh`.
- `check_eks_version_support.sh` — Bash helper script `check_eks_version_support.sh`.
