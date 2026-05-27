---
name: azure-devops-repository-health
description: Repository health monitoring for Azure DevOps focusing on code quality, security, and configuration issues that... Use when triaging or monitoring Azure, DevOps, Repository workloads with skill tem...
runtime:
  runbook: runbook.robot
  runner: ro
platforms: [Azure, DevOps, Repository, CodeQuality, Security, Troubleshooting]
resource_types: [azure_devops]
access: read-only
---

# Azure DevOps Repository Health

## Summary

This codebundle provides comprehensive repository-level health monitoring for Azure DevOps, focusing on identifying root causes of repository issues and misconfigurations that impact development workflows.

See [README.md](README.md) for additional context.

## Tools

### Investigate Recent Code Changes for Repositories in Project `${AZURE_DEVOPS_PROJECT}`

Analyze recent commits, releases, and code changes that might be causing application failures

- **Robot task name**: <code>Investigate Recent Code Changes for Repositories in Project `${AZURE_DEVOPS_PROJECT}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `recent-changes-analysis.sh`
- **Tags**: `Repository`, `Troubleshooting`, `RecentChanges`, `Commits`, `Releases`, `access:read-only`, `data:logs-bulk`
- **Reads**: `AZURE_DEVOPS_PAT`
- **Writes**: `recent_changes_analysis.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Analyze Pipeline Failures for Repositories in Project `${AZURE_DEVOPS_PROJECT}`

Review recent CI/CD pipeline failures that might be affecting application deployments

- **Robot task name**: <code>Analyze Pipeline Failures for Repositories in Project `${AZURE_DEVOPS_PROJECT}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `pipeline-failure-analysis.sh`
- **Tags**: `Repository`, `Troubleshooting`, `Pipelines`, `CI/CD`, `Failures`, `access:read-only`, `data:logs-bulk`
- **Reads**: `AZURE_DEVOPS_PAT`
- **Writes**: `pipeline_failure_analysis.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Check Repository Security Configuration for Repositories in Project `${AZURE_DEVOPS_PROJECT}`

Check repository security settings, branch policies, and access controls for misconfigurations

- **Robot task name**: <code>Check Repository Security Configuration for Repositories in Project `${AZURE_DEVOPS_PROJECT}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `repository-security-analysis.sh`
- **Tags**: `Repository`, `Security`, `Configuration`, `BranchPolicies`, `access:read-only`, `data:logs-config`
- **Reads**: `AZURE_DEVOPS_PROJECT`
- **Writes**: `repository_security_analysis.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Analyze Code Quality for Repositories in Project `${AZURE_DEVOPS_PROJECT}`

Analyze repository for code quality issues, technical debt, and maintainability problems

- **Robot task name**: <code>Analyze Code Quality for Repositories in Project `${AZURE_DEVOPS_PROJECT}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `code-quality-analysis.sh`
- **Tags**: `Repository`, `CodeQuality`, `TechnicalDebt`, `Maintainability`, `access:read-only`, `data:logs-config`
- **Reads**: `AZURE_DEVOPS_PAT`
- **Writes**: `code_quality_analysis.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Check Branch Management for Repositories in Project `${AZURE_DEVOPS_PROJECT}`

Analyze branch structure, stale branches, and merge patterns that indicate workflow issues

- **Robot task name**: <code>Check Branch Management for Repositories in Project `${AZURE_DEVOPS_PROJECT}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `branch-management-analysis.sh`
- **Tags**: `Repository`, `BranchManagement`, `Workflow`, `GitFlow`, `access:read-only`, `data:logs-config`
- **Reads**: `AZURE_DEVOPS_PAT`
- **Writes**: `branch_management_analysis.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Analyze Pull Request and Collaboration Patterns for Repositories in Project `${AZURE_DEVOPS_PROJECT}`

Examine PR review patterns, contributor activity, and collaboration health indicators

- **Robot task name**: <code>Analyze Pull Request and Collaboration Patterns for Repositories in Project `${AZURE_DEVOPS_PROJECT}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `collaboration-analysis.sh`
- **Tags**: `Repository`, `PullRequests`, `Collaboration`, `CodeReview`, `access:read-only`, `data:logs-bulk`
- **Reads**: `AZURE_DEVOPS_PAT`
- **Writes**: `collaboration_analysis.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Investigate Critical Repository Issues for Repositories in Project `${AZURE_DEVOPS_PROJECT}`

Perform comprehensive investigation of critical repository issues that might impact operations

- **Robot task name**: <code>Investigate Critical Repository Issues for Repositories in Project `${AZURE_DEVOPS_PROJECT}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `critical-repository-investigation.sh`
- **Tags**: `Repository`, `Critical`, `Investigation`, `Operations`, `access:read-only`, `data:logs-bulk`
- **Reads**: `AZURE_DEVOPS_PAT`
- **Writes**: `critical_repository_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


## Inputs

| Name | Type | Description | Default | Required |
|---|---|---|---|---|
| `AZURE_DEVOPS_ORG` | string | Azure DevOps organization name. | — | yes |
| `AZURE_DEVOPS_PROJECT` | string | Azure DevOps project name. | — | yes |
| `AZURE_DEVOPS_REPOS` | string | Repository name(s) to analyze. Can be a single repository, comma-separated list, or 'All' for all repositories in the project. | `All` | no |
| `REPO_SIZE_THRESHOLD_MB` | string | Repository size threshold in MB above which performance issues are flagged. | `500` | no |
| `STALE_BRANCH_DAYS` | string | Number of days after which branches are considered stale. | `90` | no |
| `MIN_CODE_COVERAGE` | string | Minimum code coverage percentage threshold. | `80` | no |
| `ANALYSIS_DAYS` | string | Number of days to look back for recent changes and pipeline failures analysis. | `7` | no |

## Secrets

_No secrets imported in Robot source._

## Outputs

- `recent_changes_analysis.json`
- `pipeline_failure_analysis.json`
- `repository_security_analysis.json`
- `code_quality_analysis.json`
- `branch_management_analysis.json`
- `collaboration_analysis.json`
- `critical_repository_issues.json`

## How to invoke

### Preferred: Robot Framework runner (`ro`)

```bash
cd codebundles/azure-devops-repository-health
export AZURE_DEVOPS_ORG=...
export AZURE_DEVOPS_PROJECT=...
export AZURE_DEVOPS_REPOS=...
export REPO_SIZE_THRESHOLD_MB=...
export STALE_BRANCH_DAYS=...
export MIN_CODE_COVERAGE=...
ro runbook.robot
```

### Standalone scripts (no Robot)


Set the input variables above, then run the matching script:

```bash
cd codebundles/azure-devops-repository-health
export AZURE_DEVOPS_ORG=...
export AZURE_DEVOPS_PROJECT=...
export AZURE_DEVOPS_REPOS=...
export REPO_SIZE_THRESHOLD_MB=...
bash branch-management-analysis.sh
bash code-quality-analysis.sh
bash collaboration-analysis.sh
bash critical-repository-investigation.sh
bash discover-repositories.sh
bash pipeline-failure-analysis.sh
bash recent-changes-analysis.sh
bash repository-performance-analysis.sh
bash repository-security-analysis.sh
bash security-incident-check.sh
```

## Source files

- `runbook.robot` — orchestrates tools and raises issues
- `branch-management-analysis.sh` — Bash helper script `branch-management-analysis.sh`.
- `code-quality-analysis.sh` — Bash helper script `code-quality-analysis.sh`.
- `collaboration-analysis.sh` — Bash helper script `collaboration-analysis.sh`.
- `critical-repository-investigation.sh` — Bash helper script `critical-repository-investigation.sh`.
- `discover-repositories.sh` — Bash helper script `discover-repositories.sh`.
- `pipeline-failure-analysis.sh` — Bash helper script `pipeline-failure-analysis.sh`.
- `recent-changes-analysis.sh` — Bash helper script `recent-changes-analysis.sh`.
- `repository-performance-analysis.sh` — Bash helper script `repository-performance-analysis.sh`.
- `repository-security-analysis.sh` — Bash helper script `repository-security-analysis.sh`.
- `security-incident-check.sh` — Bash helper script `security-incident-check.sh`.
