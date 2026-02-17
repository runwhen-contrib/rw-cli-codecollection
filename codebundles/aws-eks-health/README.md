# AWS EKS Cluster Health CodeBundle
### Tags: `AWS`, `EKS`, `Kubernetes`, `Cluster Health`, `Node Groups`, `Fargate`

## CodeBundle Objective
Comprehensive health checks for Amazon EKS clusters in a given AWS region. Inspects cluster status, configuration, managed add-ons, node group health/scaling, and Fargate profile state. Raises structured issues with severity levels and actionable next steps for any problems found.

## CodeBundle Inputs

On the platform: `AWS_REGION`, `aws_credentials` (from aws-auth block).

**Local testing:** Set `AWS_REGION`, and either `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` or `AWS_PROFILE`. For the runbook via CLI, add `RW_FROM_FILE='{"aws_credentials":"/path/or-placeholder"}'`.

## Runbook Tasks

### `Check EKS Cluster Health`
Checks overall EKS cluster health including:
- Cluster status (ACTIVE, UPDATING, FAILED, etc.)
- Kubernetes and platform version
- Endpoint access configuration (public/private)
- Cluster health issues from the EKS health API
- Logging configuration (warns if disabled)
- Secrets encryption configuration
- Managed add-on status and version (coredns, kube-proxy, vpc-cni, etc.)
- Managed node group summary with scaling config
- Fargate profile summary

### `Check EKS Fargate Profile Health`
Checks all Fargate profiles across EKS clusters:
- Profile status (ACTIVE, CREATING, DELETING, etc.)
- Pod execution role and subnet configuration
- Namespace selectors and label matchers
- Detects profiles with no selectors (won't schedule pods)
- Summary of healthy vs unhealthy profiles

### `Check EKS Node Group Health`
Checks all managed node groups across EKS clusters:
- Node group status and health issues
- Kubernetes version and AMI type
- Instance types and capacity type (ON_DEMAND/SPOT)
- Scaling configuration (min/desired/max)
- Detects node groups at maximum capacity
- Detects node groups with 0 desired nodes
- Summary of healthy vs unhealthy groups and total node count

## SLI Task

### `Check Amazon EKS Cluster Health Status`
Runs the cluster health check and pushes a health metric: 1 = healthy (no issues), 0 = unhealthy (issues found).
