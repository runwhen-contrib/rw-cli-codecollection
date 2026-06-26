---
name: azure-devops-project-health
kind: skill-template
description: Comprehensive Azure DevOps project health monitoring with conditional deep investigation. Use when triaging or monitoring Azure, DevOps, Projects workloads with skill template `azure-devops-project...
runtime:
  runbook: runbook.robot
  executor: worker
  entrypoint: /home/runwhen/robot-runtime/runrobot.sh
  base_image: rw-base-runtime
platforms: [Azure, DevOps, Projects, Health]
resource_types: [azure_devops]
access: read-only
---

# Azure DevOps Project Health

## Summary

This codebundle monitors Azure DevOps project health across multiple projects, identifying issues with pipelines, agent pools, repository policies, and service connections.

See [README.md](README.md) for additional context.

## Tools

### Check Agent Pool Availability Across Projects in `${AZURE_DEVOPS_ORG}`

Check agent pool health and capacity issues

- **Robot task name**: <code>Check Agent Pool Availability Across Projects in `${AZURE_DEVOPS_ORG}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `agent-pools.sh`
- **Tags**: `DevOps`, `Azure`, `Health`, `access:read-only`, `data:logs-config`
- **Reads**: `AZURE_DEVOPS_ORG`
- **Writes**: `agent_pools_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Check for Failed Pipelines Across Projects in `${AZURE_DEVOPS_ORG}`

Identify failed pipeline runs with detailed logs

- **Robot task name**: <code>Check for Failed Pipelines Across Projects in `${AZURE_DEVOPS_ORG}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `pipeline-logs.sh`
- **Tags**: `DevOps`, `Azure`, `Pipelines`, `Failures`, `access:read-only`, `data:logs-bulk`
- **Reads**: `AZURE_DEVOPS_ORG`
- **Writes**: `pipeline_logs_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Check for Long-Running Pipelines Across Projects in `${AZURE_DEVOPS_ORG}` (Threshold: ${DURATION_THRESHOLD})

Identify pipelines exceeding duration thresholds

- **Robot task name**: <code>Check for Long-Running Pipelines Across Projects in `${AZURE_DEVOPS_ORG}` (Threshold: ${DURATION_THRESHOLD})</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `long-running-pipelines.sh`
- **Tags**: `DevOps`, `Azure`, `Pipelines`, `Performance`, `access:read-only`, `data:logs-bulk`
- **Reads**: `AZURE_DEVOPS_ORG`, `DURATION_THRESHOLD`
- **Writes**: `long_running_pipelines.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Check for Queued Pipelines Across Projects in `${AZURE_DEVOPS_ORG}` (Threshold: ${QUEUE_THRESHOLD})

Identify pipelines queued beyond threshold limits

- **Robot task name**: <code>Check for Queued Pipelines Across Projects in `${AZURE_DEVOPS_ORG}` (Threshold: ${QUEUE_THRESHOLD})</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `queued-pipelines.sh`
- **Tags**: `DevOps`, `Azure`, `Pipelines`, `Queue`, `access:read-only`, `data:logs-bulk`
- **Reads**: `AZURE_DEVOPS_ORG`, `QUEUE_THRESHOLD`
- **Writes**: `queued_pipelines.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Check Repository Branch Policies Across Projects in `${AZURE_DEVOPS_ORG}`

Verify repository branch policies compliance

- **Robot task name**: <code>Check Repository Branch Policies Across Projects in `${AZURE_DEVOPS_ORG}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `repo-policies.sh`
- **Tags**: `DevOps`, `Azure`, `Repository`, `Policies`, `access:read-only`, `data:logs-config`
- **Reads**: `AZURE_DEVOPS_ORG`
- **Writes**: `repo_policies_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Check Service Connection Health Across Projects in `${AZURE_DEVOPS_ORG}`

Verify service connection availability and readiness

- **Robot task name**: <code>Check Service Connection Health Across Projects in `${AZURE_DEVOPS_ORG}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `service-connections.sh`
- **Tags**: `DevOps`, `Azure`, `ServiceConnections`, `access:read-only`, `data:logs-config`
- **Reads**: `AZURE_DEVOPS_ORG`
- **Writes**: `service_connections_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Investigate Pipeline Performance Issues Across Projects in `${AZURE_DEVOPS_ORG}`

Analyze pipeline performance trends and bottlenecks

- **Robot task name**: <code>Investigate Pipeline Performance Issues Across Projects in `${AZURE_DEVOPS_ORG}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `pipeline-performance-analysis.sh`
- **Tags**: `Investigation`, `Performance`, `Trends`, `Bottlenecks`, `access:read-only`, `data:logs-bulk`
- **Reads**: `AZURE_DEVOPS_ORG`
- **Writes**: `pipeline_performance_analysis.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Investigate Failed Pipeline Runs with Commit Correlation Across Projects in `${AZURE_DEVOPS_ORG}`

Correlate failed pipeline runs with recent commits to identify what changed and caused failures

- **Robot task name**: <code>Investigate Failed Pipeline Runs with Commit Correlation Across Projects in `${AZURE_DEVOPS_ORG}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `pipeline-failure-investigation.sh`
- **Tags**: `DevOps`, `Azure`, `Pipelines`, `Investigation`, `Commits`, `access:read-only`, `data:logs-bulk`
- **Reads**: `AZURE_DEVOPS_ORG`
- **Writes**: `pipeline_failure_investigation.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Analyze Recent Repository Activity Across Projects in `${AZURE_DEVOPS_ORG}`

Summarize recent commit activity, pull request status, and branch health across all project repositories to show what changed

- **Robot task name**: <code>Analyze Recent Repository Activity Across Projects in `${AZURE_DEVOPS_ORG}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `repository-health-analysis.sh`
- **Tags**: `DevOps`, `Azure`, `Repository`, `Activity`, `Commits`, `access:read-only`, `data:logs-bulk`
- **Reads**: `AZURE_DEVOPS_ORG`
- **Writes**: `repository_health_analysis.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


## Inputs

| Name | Type | Description | Default | Required |
|---|---|---|---|---|
| `AZURE_DEVOPS_ORG` | string | Azure DevOps organization name. | — | yes |
| `AZURE_DEVOPS_PROJECTS` | string | Comma-separated list of Azure DevOps projects to monitor (e.g., "project1,project2,project3") or "All" to monitor all projects. | `All` | no |
| `DURATION_THRESHOLD` | string | Threshold for long-running pipelines (format: 60m, 2h) | `60m` | no |
| `QUEUE_THRESHOLD` | string | Threshold for queued pipelines (format: 10m, 1h) | `30m` | no |

## Secrets

_No secrets imported in Robot source._

## Outputs

- `agent_pools_issues.json`
- `pipeline_logs_issues.json`
- `long_running_pipelines.json`
- `queued_pipelines.json`
- `repo_policies_issues.json`
- `service_connections_issues.json`
- `pipeline_performance_analysis.json`
- `pipeline_failure_investigation.json`
- `repository_health_analysis.json`

## How to invoke

### Production (RunWhen runner / worker)

The platform **runner** schedules work on a location **worker**. The worker
image (`rw-base-runtime`) executes Robot via `runrobot.sh` with
`RW_PATH_TO_ROBOT` set to the bound path under `/home/runwhen/collection/`.

- **Runbook**: `codebundles/azure-devops-project-health/runbook.robot`

### Local development (devcontainer only)

`ro` is a dev-time wrapper in `codecollection-devtools` — not the enterprise runtime.

```bash
cd codebundles/azure-devops-project-health
export AZURE_DEVOPS_ORG=...
export AZURE_DEVOPS_PROJECTS=...
export DURATION_THRESHOLD=...
export QUEUE_THRESHOLD=...
ro runbook.robot
```

### Standalone scripts (no Robot)


Set the input variables above, then run the matching script:

```bash
cd codebundles/azure-devops-project-health
export AZURE_DEVOPS_ORG=...
export AZURE_DEVOPS_PROJECTS=...
export DURATION_THRESHOLD=...
export QUEUE_THRESHOLD=...
bash _az_helpers.sh
bash agent-pools.sh
bash discover-projects.sh
bash long-running-pipelines.sh
bash pipeline-failure-investigation.sh
bash pipeline-logs.sh
bash pipeline-performance-analysis.sh
bash preflight-check.sh
bash queued-pipelines.sh
bash repo-policies.sh
bash repository-health-analysis.sh
bash service-connections.sh
```

## Source files

- `runbook.robot` — orchestrates tools and raises issues
- `_az_helpers.sh` — Bash helper script `_az_helpers.sh`.
- `agent-pools.sh` — Bash helper script `agent-pools.sh`.
- `discover-projects.sh` — Bash helper script `discover-projects.sh`.
- `long-running-pipelines.sh` — Bash helper script `long-running-pipelines.sh`.
- `pipeline-failure-investigation.sh` — Bash helper script `pipeline-failure-investigation.sh`.
- `pipeline-logs.sh` — Bash helper script `pipeline-logs.sh`.
- `pipeline-performance-analysis.sh` — Bash helper script `pipeline-performance-analysis.sh`.
- `preflight-check.sh` — Bash helper script `preflight-check.sh`.
- `queued-pipelines.sh` — Bash helper script `queued-pipelines.sh`.
- `repo-policies.sh` — Bash helper script `repo-policies.sh`.
- `repository-health-analysis.sh` — Bash helper script `repository-health-analysis.sh`.
- `service-connections.sh` — Bash helper script `service-connections.sh`.
