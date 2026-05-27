---
name: gh-actions-health
description: Comprehensive health monitoring for GitHub Actions across specified repositories and organizations. Use when triaging or monitoring GitHub, Actions workloads with skill template `gh-actions-health`.
runtime:
  runbook: runbook.robot
  monitor: sli.robot
  runner: ro
platforms: [GitHub, Actions]
resource_types: []
access: read-only
---

# GitHub Actions Health Monitoring

## Summary

Comprehensive health monitoring for GitHub Actions across specified repositories and organizations.

See [README.md](README.md) for additional context.

## Tools

### Check Recent Workflow Failures Across Specified Repositories

Analyzes recent workflow failures across the specified repositories and identifies common failure patterns

- **Robot task name**: <code>Check Recent Workflow Failures Across Specified Repositories</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `check_workflow_failures.sh`
- **Tags**: —
- **Reads**: `GITHUB_TOKEN`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Check Long Running Workflows Across Specified Repositories

Identifies workflows that have been running longer than expected thresholds across the specified repositories

- **Robot task name**: <code>Check Long Running Workflows Across Specified Repositories</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `check_long_running_workflows.sh`
- **Tags**: —
- **Reads**: `GITHUB_TOKEN`, `MAX_WORKFLOW_DURATION_MINUTES`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Check Repository Health Summary for Specified Repositories

Provides a comprehensive health summary across the specified repositories

- **Robot task name**: <code>Check Repository Health Summary for Specified Repositories</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `check_repo_health_summary.sh`
- **Tags**: —
- **Reads**: `GITHUB_TOKEN`, `REPO_FAILURE_THRESHOLD`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Check GitHub Actions Runner Health Across Specified Organizations

Monitors the health and availability of GitHub Actions runners across the specified organizations

- **Robot task name**: <code>Check GitHub Actions Runner Health Across Specified Organizations</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `check_runner_health.sh`
- **Tags**: —
- **Reads**: `GITHUB_TOKEN`, `HIGH_RUNNER_UTILIZATION_THRESHOLD`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Check Security Workflow Status Across Specified Repositories

Monitors security-related workflows and dependency scanning results across the specified repositories

- **Robot task name**: <code>Check Security Workflow Status Across Specified Repositories</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `check_security_workflows.sh`
- **Tags**: —
- **Reads**: `GITHUB_TOKEN`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Check GitHub Actions Billing and Usage Across Specified Organizations

Monitors GitHub Actions usage patterns and potential billing concerns across the specified organizations

- **Robot task name**: <code>Check GitHub Actions Billing and Usage Across Specified Organizations</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `check_billing_usage.sh`
- **Tags**: —
- **Reads**: `GITHUB_TOKEN`, `HIGH_USAGE_THRESHOLD`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Check GitHub API Rate Limits

Monitors GitHub API rate limit usage to prevent throttling during health checks

- **Robot task name**: <code>Check GitHub API Rate Limits</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `check_rate_limits.sh`
- **Tags**: —
- **Reads**: `GITHUB_TOKEN`, `RATE_LIMIT_WARNING_THRESHOLD`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


## Monitor

Service Level Indicators for GitHub Actions Health Monitoring

- **Robot file**: `sli.robot`
- **Score range**: `0.0` (failing) to `1.0` (healthy)
- **Aggregation**: arithmetic mean of the sub-checks below
- **Recommended interval**: `180s`

### Sub-checks

#### Calculate Workflow Success Rate Across Specified Repositories

Calculates the success rate of workflows across the specified repositories over the specified period

- **Robot task name**: <code>Calculate Workflow Success Rate Across Specified Repositories</code>
- **Sub-metric name**: `workflow_success`
- **Underlying script**: `calculate_workflow_sli.sh`
- **Tags**: `github`, `workflow`, `success-rate`, `sli`, `multi-repo`
- **Reads**: `GITHUB_TOKEN`, `MIN_WORKFLOW_SUCCESS_RATE`
- **Pass condition**: `float(${success_rate}) >= float(${MIN_WORKFLOW_SUCCESS_RATE})`


#### Calculate Organization Health Score Across Specified Organizations

Calculates overall organization health score across all specified organizations

- **Robot task name**: <code>Calculate Organization Health Score Across Specified Organizations</code>
- **Sub-metric name**: `org_health`
- **Underlying script**: `calculate_org_sli.sh`
- **Tags**: `github`, `organization`, `health-score`, `sli`, `multi-org`
- **Reads**: `GITHUB_TOKEN`, `MIN_ORG_HEALTH_SCORE`
- **Pass condition**: `float(${org_health_score}) >= float(${MIN_ORG_HEALTH_SCORE})`


#### Calculate Runner Availability Score Across Specified Organizations

Calculates the availability score of GitHub Actions runners across the specified organizations

- **Robot task name**: <code>Calculate Runner Availability Score Across Specified Organizations</code>
- **Sub-metric name**: `runner_availability`
- **Underlying script**: `calculate_runner_sli.sh`
- **Tags**: `github`, `runners`, `availability`, `sli`, `multi-org`
- **Reads**: `GITHUB_TOKEN`, `MIN_RUNNER_AVAILABILITY`
- **Pass condition**: `float(${availability_score}) >= float(${MIN_RUNNER_AVAILABILITY})`


#### Calculate Security Workflow Score Across Specified Repositories

Calculates security workflow health score including vulnerability scanning across the specified repositories

- **Robot task name**: <code>Calculate Security Workflow Score Across Specified Repositories</code>
- **Sub-metric name**: `security_workflows`
- **Underlying script**: `calculate_security_sli.sh`
- **Tags**: `github`, `security`, `vulnerability`, `sli`, `multi-repo`
- **Reads**: `GITHUB_TOKEN`, `MIN_SECURITY_SCORE`
- **Pass condition**: `float(${security_score}) >= float(${MIN_SECURITY_SCORE}) and int(${critical_vulnerabilities}) == 0`


#### Calculate Performance Score Across Specified Repositories

Calculates workflow performance score based on execution times across the specified repositories

- **Robot task name**: <code>Calculate Performance Score Across Specified Repositories</code>
- **Sub-metric name**: `workflow_performance`
- **Underlying script**: `calculate_performance_sli.sh`
- **Tags**: `github`, `performance`, `duration`, `sli`, `multi-repo`
- **Reads**: `GITHUB_TOKEN`, `MAX_LONG_RUNNING_WORKFLOWS`, `MIN_PERFORMANCE_SCORE`
- **Pass condition**: `float(${performance_score}) >= float(${MIN_PERFORMANCE_SCORE}) and int(${long_running_count}) <= int(${MAX_LONG_RUNNING_WORKFLOWS})`


#### Calculate API Rate Limit Health Score

Calculates GitHub API rate limit utilization health score

- **Robot task name**: <code>Calculate API Rate Limit Health Score</code>
- **Sub-metric name**: `api_rate_limit`
- **Underlying script**: `calculate_rate_limit_sli.sh`
- **Tags**: `github`, `api`, `rate-limit`, `sli`
- **Reads**: `GITHUB_TOKEN`, `MAX_RATE_LIMIT_USAGE`
- **Pass condition**: `float(${usage_percentage}) <= float(${MAX_RATE_LIMIT_USAGE})`


## Inputs

| Name | Type | Description | Default | Required |
|---|---|---|---|---|
| `GITHUB_REPOS` | string | Comma-separated list of GitHub repositories in format owner/repo, or 'ALL' for all org repositories | `ALL` | no |
| `GITHUB_ORGS` | string | GitHub organization names (single org or comma-separated list for multiple orgs) | `""` | no |
| `MAX_WORKFLOW_DURATION_MINUTES` | string | Maximum expected workflow duration in minutes | `60` | no |
| `REPO_FAILURE_THRESHOLD` | string | Maximum number of workflow failures allowed across specified repositories | `10` | no |
| `HIGH_RUNNER_UTILIZATION_THRESHOLD` | string | Threshold percentage for high runner utilization warning | `80` | no |
| `HIGH_USAGE_THRESHOLD` | string | Threshold percentage for high billing usage warning | `80` | no |
| `RATE_LIMIT_WARNING_THRESHOLD` | string | Threshold percentage for GitHub API rate limit warning | `70` | no |
| `FAILURE_LOOKBACK_DAYS` | string | Number of days to look back for workflow failures. Accepts partial numbers (e.g. 0.04 = 1h) | `1` | no |
| `MAX_REPOS_TO_ANALYZE` | string | Maximum number of repositories to analyze when GITHUB_REPOS is 'ALL' (0 for unlimited) | `0` | no |
| `MAX_REPOS_PER_ORG` | string | Maximum number of repositories to analyze per organization when using 'ALL' (0 for unlimited) | `0` | no |
| `MIN_WORKFLOW_SUCCESS_RATE` | string | Minimum acceptable workflow success rate (0.0-1.0) | `0.95` | no |
| `MIN_ORG_HEALTH_SCORE` | string | Minimum acceptable organization health score (0.0-1.0) | `0.90` | no |
| `MIN_RUNNER_AVAILABILITY` | string | Minimum acceptable runner availability score (0.0-1.0) | `0.95` | no |
| `MIN_SECURITY_SCORE` | string | Minimum acceptable security workflow score (0.0-1.0) | `0.98` | no |
| `MIN_PERFORMANCE_SCORE` | string | Minimum acceptable workflow performance score (0.0-1.0) | `0.90` | no |
| `MAX_RATE_LIMIT_USAGE` | string | Maximum acceptable API rate limit usage percentage | `70` | no |
| `MAX_LONG_RUNNING_WORKFLOWS` | string | Maximum number of long-running workflows considered healthy | `2` | no |
| `SLI_LOOKBACK_DAYS` | string | Number of days to look back for SLI calculations | `7` | no |

## Secrets

| Name | Description | Required |
|---|---|---|
| `GITHUB_TOKEN` | GitHub Personal Access Token with appropriate permissions | yes |

## Outputs

- Monitor health score (`0.0`–`1.0`) pushed by `sli.robot`

## How to invoke

### Preferred: Robot Framework runner (`ro`)

```bash
cd codebundles/gh-actions-health
export GITHUB_REPOS=...
export GITHUB_ORGS=...
export MAX_WORKFLOW_DURATION_MINUTES=...
export REPO_FAILURE_THRESHOLD=...
export HIGH_RUNNER_UTILIZATION_THRESHOLD=...
ro runbook.robot
```

### Standalone scripts (no Robot)


Set the input variables above, then run the matching script:

```bash
cd codebundles/gh-actions-health
export GITHUB_REPOS=...
export GITHUB_ORGS=...
export MAX_WORKFLOW_DURATION_MINUTES=...
bash calculate_org_sli.sh
bash calculate_performance_sli.sh
bash calculate_rate_limit_sli.sh
bash calculate_runner_sli.sh
bash calculate_security_sli.sh
bash calculate_workflow_sli.sh
bash check_billing_usage.sh
bash check_long_running_workflows.sh
bash check_org_workflow_health.sh
bash check_rate_limits.sh
bash check_repo_health_summary.sh
bash check_runner_health.sh
# ... and 2 more scripts
```

## Source files

- `runbook.robot` — orchestrates tools and raises issues
- `sli.robot` — monitor scoring (`sli.robot` runtime file)
- `calculate_org_sli.sh` — Bash helper script `calculate_org_sli.sh`.
- `calculate_performance_sli.sh` — Bash helper script `calculate_performance_sli.sh`.
- `calculate_rate_limit_sli.sh` — Bash helper script `calculate_rate_limit_sli.sh`.
- `calculate_runner_sli.sh` — Bash helper script `calculate_runner_sli.sh`.
- `calculate_security_sli.sh` — Bash helper script `calculate_security_sli.sh`.
- `calculate_workflow_sli.sh` — Bash helper script `calculate_workflow_sli.sh`.
- `check_billing_usage.sh` — Bash helper script `check_billing_usage.sh`.
- `check_long_running_workflows.sh` — Bash helper script `check_long_running_workflows.sh`.
- `check_org_workflow_health.sh` — Bash helper script `check_org_workflow_health.sh`.
- `check_rate_limits.sh` — Bash helper script `check_rate_limits.sh`.
- `check_repo_health_summary.sh` — Bash helper script `check_repo_health_summary.sh`.
- `check_runner_health.sh` — Bash helper script `check_runner_health.sh`.
- `check_security_workflows.sh` — Bash helper script `check_security_workflows.sh`.
- `check_workflow_failures.sh` — Bash helper script `check_workflow_failures.sh`.
