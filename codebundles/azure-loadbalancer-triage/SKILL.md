---
name: azure-loadbalancer-triage
description: Triages issues related to a Azure Loadbalancers and its activity logs. Use when triaging or monitoring Kubernetes, AKS, Azure workloads with skill template `azure-loadbalancer-triage`.
runtime:
  runbook: runbook.robot
  runner: ro
platforms: [Kubernetes, AKS, Azure]
resource_types: [load_balancer]
access: read-only
---

# Azure Internal LoadBalancer Triage

## Summary

Queries the activity logs of internal loadbalancers (AKS ingress) objects in Azure and optionally inspects internal AKS ingress objects if available.

See [README.md](README.md) for additional context.

## Tools

### Check Activity Logs for Azure Load Balancer `${AZ_LB_NAME}`

Queries a Azure Loadbalancer's health probe to determine if it's in a healthy state.

- **Robot task name**: <code>Check Activity Logs for Azure Load Balancer `${AZ_LB_NAME}`</code>
- **Robot file**: `runbook.robot`
- **Tags**: `loadbalancer`, `network`, `azure`, `${az_lb_name}`, `data:logs-bulk`
- **Reads**: `AZURE_RESOURCE_SUBSCRIPTION_ID`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


## Inputs

| Name | Type | Description | Default | Required |
|---|---|---|---|---|
| `AZURE_RESOURCE_SUBSCRIPTION_ID` | string | The Azure Subscription ID for the resource. | `""` | no |

## Secrets

_No secrets imported in Robot source._

## Outputs

_See Robot run output and platform report artifacts._

## How to invoke

### Preferred: Robot Framework runner (`ro`)

```bash
cd codebundles/azure-loadbalancer-triage
export AZURE_RESOURCE_SUBSCRIPTION_ID=...
ro runbook.robot
```

### Standalone scripts (no Robot)


_No standalone shell scripts in this bundle._

## Source files

- `runbook.robot` — orchestrates tools and raises issues
