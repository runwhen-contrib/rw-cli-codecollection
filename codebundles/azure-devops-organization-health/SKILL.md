---
name: azure-devops-organization-health
description: Comprehensive Azure DevOps organization health monitoring focusing on platform-wide issues and shared resources. Use when triaging or monitoring AzureDevOps, CICD workloads with skill template `azu...
runtime:
  runbook: runbook.robot
  runner: ro
platforms: [AzureDevOps, CICD]
resource_types: [azure_devops]
access: read-only
---

# Azure DevOps Organization Health

## Summary

This codebundle provides comprehensive health monitoring for Azure DevOps organizations, focusing on platform-wide issues, shared resources, and organizational capacity management.

See [README.md](README.md) for additional context.

## Tools

### Check Service Health Status for Azure DevOps Organization `${AZURE_DEVOPS_ORG}`

Tests connectivity and access to core Azure DevOps APIs and services. Identifies service issues vs permission limitations.

- **Robot task name**: <code>Check Service Health Status for Azure DevOps Organization `${AZURE_DEVOPS_ORG}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `organization-service-health.sh`
- **Tags**: `Organization`, `Service`, `Health`, `Platform`, `access:read-only`, `data:logs-config`
- **Reads**: `AZURE_DEVOPS_ORG`
- **Writes**: `organization_service_health.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Check Agent Pool Capacity and Utilization for Organization `${AZURE_DEVOPS_ORG}`

Analyzes self-hosted agent pools for capacity issues including offline agents, utilization thresholds, and configuration problems.

- **Robot task name**: <code>Check Agent Pool Capacity and Utilization for Organization `${AZURE_DEVOPS_ORG}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `agent-pool-capacity.sh`
- **Tags**: `Organization`, `AgentPools`, `Capacity`, `Distribution`, `access:read-only`, `data:logs-bulk`
- **Reads**: `AZURE_DEVOPS_ORG`
- **Writes**: `agent_pool_capacity.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Validate Organization Policies and Security Settings for `${AZURE_DEVOPS_ORG}`

Examines organization security groups, user access levels, and policy configurations. Requires elevated permissions for full analysis.

- **Robot task name**: <code>Validate Organization Policies and Security Settings for `${AZURE_DEVOPS_ORG}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `organization-policies.sh`
- **Tags**: `Organization`, `Policies`, `Compliance`, `Security`, `access:read-only`, `data:logs-config`
- **Reads**: `AZURE_DEVOPS_ORG`
- **Writes**: `organization_policies.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Check License Utilization and Capacity for Organization `${AZURE_DEVOPS_ORG}`

Analyzes user license assignments for cost optimization opportunities and identifies inactive users or licensing inefficiencies.

- **Robot task name**: <code>Check License Utilization and Capacity for Organization `${AZURE_DEVOPS_ORG}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `license-utilization.sh`
- **Tags**: `Organization`, `Licenses`, `Capacity`, `Utilization`, `access:read-only`, `data:logs-config`
- **Reads**: `AZURE_DEVOPS_ORG`
- **Writes**: `license_utilization.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Investigate Platform-wide Service Incidents for Organization `${AZURE_DEVOPS_ORG}`

Monitors Azure DevOps platform status and detects service-wide incidents by checking official status pages and API performance.

- **Robot task name**: <code>Investigate Platform-wide Service Incidents for Organization `${AZURE_DEVOPS_ORG}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `service-incident-check.sh`
- **Tags**: `Organization`, `Incidents`, `Platform`, `Service`, `access:read-only`, `data:logs-bulk`
- **Reads**: `AZURE_DEVOPS_ORG`
- **Writes**: `service_incidents.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Analyze Cross-Project Dependencies for Organization `${AZURE_DEVOPS_ORG}`

Identifies shared resources between projects including agent pools, service connections, and potential naming conflicts.

- **Robot task name**: <code>Analyze Cross-Project Dependencies for Organization `${AZURE_DEVOPS_ORG}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `cross-project-dependencies.sh`
- **Tags**: `Organization`, `Dependencies`, `Projects`, `Integration`, `access:read-only`, `data:logs-config`
- **Reads**: `AZURE_DEVOPS_ORG`
- **Writes**: `cross_project_dependencies.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Investigate Platform Issues for Organization `${AZURE_DEVOPS_ORG}`

Performs detailed investigation of agent pool issues and analyzes recent pipeline failures across all projects.

- **Robot task name**: <code>Investigate Platform Issues for Organization `${AZURE_DEVOPS_ORG}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `platform-issue-investigation.sh`
- **Tags**: `Organization`, `Investigation`, `Platform`, `Performance`, `access:read-only`, `data:logs-bulk`
- **Reads**: `AZURE_DEVOPS_ORG`
- **Writes**: `platform_issue_investigation.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


## Inputs

| Name | Type | Description | Default | Required |
|---|---|---|---|---|
| `AZURE_DEVOPS_ORG` | string | Azure DevOps organization name. | — | yes |
| `AGENT_UTILIZATION_THRESHOLD` | string | Agent pool utilization threshold percentage (0-100) above which capacity issues are flagged. | `80` | no |
| `LICENSE_UTILIZATION_THRESHOLD` | string | License utilization threshold percentage (0-100) above which licensing issues are flagged. | `90` | no |

## Secrets

_No secrets imported in Robot source._

## Outputs

- `organization_service_health.json`
- `agent_pool_capacity.json`
- `organization_policies.json`
- `license_utilization.json`
- `service_incidents.json`
- `cross_project_dependencies.json`
- `platform_issue_investigation.json`

## How to invoke

### Preferred: Robot Framework runner (`ro`)

```bash
cd codebundles/azure-devops-organization-health
export AZURE_DEVOPS_ORG=...
export AGENT_UTILIZATION_THRESHOLD=...
export LICENSE_UTILIZATION_THRESHOLD=...
ro runbook.robot
```

### Standalone scripts (no Robot)


Set the input variables above, then run the matching script:

```bash
cd codebundles/azure-devops-organization-health
export AZURE_DEVOPS_ORG=...
export AGENT_UTILIZATION_THRESHOLD=...
export LICENSE_UTILIZATION_THRESHOLD=...
bash agent-pool-capacity.sh
bash cross-project-dependencies.sh
bash license-utilization.sh
bash organization-policies.sh
bash organization-service-health.sh
bash platform-issue-investigation.sh
bash service-incident-check.sh
```

## Source files

- `runbook.robot` — orchestrates tools and raises issues
- `agent-pool-capacity.sh` — Bash helper script `agent-pool-capacity.sh`.
- `cross-project-dependencies.sh` — Bash helper script `cross-project-dependencies.sh`.
- `license-utilization.sh` — Bash helper script `license-utilization.sh`.
- `organization-policies.sh` — Bash helper script `organization-policies.sh`.
- `organization-service-health.sh` — Bash helper script `organization-service-health.sh`.
- `platform-issue-investigation.sh` — Bash helper script `platform-issue-investigation.sh`.
- `service-incident-check.sh` — Bash helper script `service-incident-check.sh`.
