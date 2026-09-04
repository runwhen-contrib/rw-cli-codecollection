---
name: gh-repo-health
kind: skill-template
description: This taskset monitors repository health across GitHub organizations — dormant repos, stale issues/PRs, branch hygiene, config health, release cadence, and contributor pulse. Use when triaging or monitoring GitHub repository health with skill template `gh-repo-health`.
runtime:
  runbook: runbook.robot
  monitor: sli.robot
  executor: worker
  entrypoint: /home/runwhen/robot-runtime/runrobot.sh
  base_image: rw-base-runtime
platforms: [GitHub]
resource_types: []
access: read-only
---

# GitHub Repository Health

## Summary

This codebundle monitors repository health across GitHub organizations. It
detects dormant repos, stale issues/PRs, branch hygiene problems, missing
config files, release cadence gaps, and builds a contributor activity pulse.

See [README.md](README.md) for additional context.

## Tools

### Detect Dormant Repositories

Find repositories with no git pushes in the last N days.

- **Robot task name**: <code>Detect Dormant Repositories</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `check_dormant_repos.sh`
- **Tags**: `github`, `repositories`, `dormant`, `multi-repo`, `multi-org`, `access:read-only`, `data:config`
- **Reads**: `GITHUB_TOKEN`, `GITHUB_APP_ID`, `GITHUB_APP_INSTALLATION_ID`, `GITHUB_APP_CLIENT_ID`, `GITHUB_APP_PRIVATE_KEY`, `DORMANT_DAYS`
- **Writes**: —
- **Issues raised**: when repos exceed `DORMANT_DAYS` without a push, severity 3 (archived) or 4 (dormant)

### Detect Stale Issue Accumulation

Identify repos where open issues are stacking up or going unresponded.

- **Robot task name**: <code>Detect Stale Issue Accumulation</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `check_stale_issues.sh`
- **Tags**: `github`, `issues`, `stale`, `backlog`, `multi-repo`, `multi-org`, `access:read-only`, `data:config`
- **Reads**: `GITHUB_TOKEN`, `GITHUB_APP_ID`, `GITHUB_APP_INSTALLATION_ID`, `GITHUB_APP_CLIENT_ID`, `GITHUB_APP_PRIVATE_KEY`, `STALE_ISSUE_DAYS`, `STALE_ISSUE_THRESHOLD`
- **Writes**: —
- **Issues raised**: when total stale issues exceed threshold (severity 3), or individual issues lack team response (severity 4)

### Detect Stale Pull Requests

Find PRs open too long, unreviewed, or with merge conflicts.

- **Robot task name**: <code>Detect Stale Pull Requests</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `check_stale_prs.sh`
- **Tags**: `github`, `pull-requests`, `stale`, `review-bottleneck`, `multi-repo`, `multi-org`, `access:read-only`, `data:config`
- **Reads**: `GITHUB_TOKEN`, `GITHUB_APP_ID`, `GITHUB_APP_INSTALLATION_ID`, `GITHUB_APP_CLIENT_ID`, `GITHUB_APP_PRIVATE_KEY`, `STALE_PR_DAYS`
- **Writes**: —
- **Issues raised**: stale PRs (severity 3), merge conflicts (severity 3), unreviewed PRs

### Audit Branch Hygiene

Find stale branches that haven't been touched in N days.

- **Robot task name**: <code>Audit Branch Hygiene</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `check_branch_hygiene.sh`
- **Tags**: `github`, `branches`, `hygiene`, `multi-repo`, `multi-org`, `access:read-only`, `data:config`
- **Reads**: `GITHUB_TOKEN`, `GITHUB_APP_ID`, `GITHUB_APP_INSTALLATION_ID`, `GITHUB_APP_CLIENT_ID`, `GITHUB_APP_PRIVATE_KEY`, `STALE_BRANCH_DAYS`
- **Writes**: —
- **Issues raised**: stale branches (severity 4)

### Audit Repository Configuration Health

Audit repos for essential files and best practices.

- **Robot task name**: <code>Audit Repository Configuration Health</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `check_repo_config_health.sh`
- **Tags**: `github`, `configuration`, `community-health`, `best-practices`, `multi-repo`, `multi-org`, `access:read-only`, `data:config`
- **Reads**: `GITHUB_TOKEN`, `GITHUB_APP_ID`, `GITHUB_APP_INSTALLATION_ID`, `GITHUB_APP_CLIENT_ID`, `GITHUB_APP_PRIVATE_KEY`
- **Writes**: —
- **Issues raised**: repos missing README, LICENSE, CONTRIBUTING, CODEOWNERS, or branch protection (severity 4)

### Check Release Health and Cadence

Check release frequency and flag overdue releases.

- **Robot task name**: <code>Check Release Health and Cadence</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `check_release_health.sh`
- **Tags**: `github`, `releases`, `cadence`, `multi-repo`, `multi-org`, `access:read-only`, `data:config`
- **Reads**: `GITHUB_TOKEN`, `GITHUB_APP_ID`, `GITHUB_APP_INSTALLATION_ID`, `GITHUB_APP_CLIENT_ID`, `GITHUB_APP_PRIVATE_KEY`, `OVERDUE_COMMIT_THRESHOLD`
- **Writes**: —
- **Issues raised**: repos with overdue releases (severity 3)

### Generate Contributor Activity Pulse

Build a per-person activity summary — commits, PRs, and review bottlenecks.

- **Robot task name**: <code>Generate Contributor Activity Pulse</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `check_contributor_pulse.sh`
- **Tags**: `github`, `contributors`, `pulse`, `review-bottleneck`, `multi-repo`, `multi-org`, `access:read-only`, `data:config`
- **Reads**: `GITHUB_TOKEN`, `GITHUB_APP_ID`, `GITHUB_APP_INSTALLATION_ID`, `GITHUB_APP_CLIENT_ID`, `GITHUB_APP_PRIVATE_KEY`, `PULSE_DAYS`
- **Writes**: —
- **Issues raised**: PRs blocked on review (severity 3)


## Monitor

This SLI calculates a composite repository health score from five sub-metrics.

- **Robot file**: `sli.robot`
- **Score range**: `0.0` (failing) to `1.0` (healthy)
- **Aggregation**: weighted arithmetic mean
- **Recommended interval**: `14400s` (4 hours)

### Sub-checks

#### Calculate Dormant Repository Score
- **Robot task name**: <code>Calculate Dormant Repository Score</code>
- **Sub-metric name**: `dormant_repos`
- **Underlying script**: `check_dormant_repos.sh`
- **Weight**: 15%
- **Tags**: `github`, `repositories`, `dormant`, `sli`, `multi-repo`
- **Reads**: `GITHUB_TOKEN`, `GITHUB_APP_ID`, `GITHUB_APP_INSTALLATION_ID`, `GITHUB_APP_CLIENT_ID`, `GITHUB_APP_PRIVATE_KEY`, `DORMANT_DAYS`

#### Calculate Issue Health Score
- **Robot task name**: <code>Calculate Issue Health Score</code>
- **Sub-metric name**: `issue_health`
- **Underlying script**: `check_stale_issues.sh`
- **Weight**: 20%
- **Tags**: `github`, `issues`, `stale`, `sli`, `multi-repo`
- **Reads**: `GITHUB_TOKEN`, `GITHUB_APP_ID`, `GITHUB_APP_INSTALLATION_ID`, `GITHUB_APP_CLIENT_ID`, `GITHUB_APP_PRIVATE_KEY`, `STALE_ISSUE_DAYS`

#### Calculate PR Health Score
- **Robot task name**: <code>Calculate PR Health Score</code>
- **Sub-metric name**: `pr_health`
- **Underlying script**: `check_stale_prs.sh`
- **Weight**: 20%
- **Tags**: `github`, `pull-requests`, `stale`, `sli`, `multi-repo`
- **Reads**: `GITHUB_TOKEN`, `GITHUB_APP_ID`, `GITHUB_APP_INSTALLATION_ID`, `GITHUB_APP_CLIENT_ID`, `GITHUB_APP_PRIVATE_KEY`, `STALE_PR_DAYS`

#### Calculate Config Health Score
- **Robot task name**: <code>Calculate Config Health Score</code>
- **Sub-metric name**: `config_health`
- **Underlying script**: `check_repo_config_health.sh`
- **Weight**: 20%
- **Tags**: `github`, `configuration`, `community-health`, `sli`, `multi-repo`
- **Reads**: `GITHUB_TOKEN`, `GITHUB_APP_ID`, `GITHUB_APP_INSTALLATION_ID`, `GITHUB_APP_CLIENT_ID`, `GITHUB_APP_PRIVATE_KEY`

#### Calculate Release Cadence Score
- **Robot task name**: <code>Calculate Release Cadence Score</code>
- **Sub-metric name**: `release_health`
- **Underlying script**: `check_release_health.sh`
- **Weight**: 25%
- **Tags**: `github`, `releases`, `cadence`, `sli`, `multi-repo`
- **Reads**: `GITHUB_TOKEN`, `GITHUB_APP_ID`, `GITHUB_APP_INSTALLATION_ID`, `GITHUB_APP_CLIENT_ID`, `GITHUB_APP_PRIVATE_KEY`, `OVERDUE_COMMIT_THRESHOLD`

## Inputs

| Name | Type | Description | Default | Required |
|---|---|---|---|---|
| `GITHUB_REPOS` | string | Comma-separated repos (owner/repo) or `ALL` | `ALL` | no |
| `GITHUB_ORGS` | string | Organization names (comma-separated) | `""` | no |
| `DORMANT_DAYS` | string | Days without push before dormant | `90` | no |
| `STALE_ISSUE_DAYS` | string | Days without update before stale issue | `60` | no |
| `STALE_ISSUE_THRESHOLD` | string | Total stale issues alert threshold | `20` | no |
| `STALE_PR_DAYS` | string | Days open before stale PR | `14` | no |
| `STALE_BRANCH_DAYS` | string | Days since commit before stale branch | `60` | no |
| `OVERDUE_COMMIT_THRESHOLD` | string | Unreleased commits before release overdue | `30` | no |
| `PULSE_DAYS` | string | Days to look back for contributor pulse | `7` | no |
| `MAX_REPOS_TO_ANALYZE` | string | Max repos total (0 = unlimited) | `0` | no |
| `MAX_REPOS_PER_ORG` | string | Max repos per org (0 = unlimited) | `0` | no |

## Secrets

| Name | Description | Required |
|---|---|---|
| `GITHUB_TOKEN` | GitHub Personal Access Token with appropriate permissions | no (if using GitHub App) |
| `GITHUB_APP_ID` | GitHub App ID for authentication | no (if using PAT) |
| `GITHUB_APP_INSTALLATION_ID` | GitHub App Installation ID (auto-discovered if unset) | no |
| `GITHUB_APP_CLIENT_ID` | GitHub App Client ID (used to auto-discover installations) | no (if using PAT) |
| `GITHUB_APP_PRIVATE_KEY` | GitHub App Private Key (PEM format) | no (if using PAT) |

> Either `GITHUB_TOKEN` **or** all three GitHub App credentials must be provided. `GITHUB_APP_INSTALLATION_ID` is optional — if unset it will be auto-discovered via the API.

## Outputs

- Monitor health score (`0.0`–`1.0`) pushed by `sli.robot`
- Detailed JSON reports appended to the runbook output for each task

## How to invoke

### Production (RunWhen runner / worker)

The platform **runner** schedules work on a location **worker**. The worker
image (`rw-base-runtime`) executes Robot via `runrobot.sh` with
`RW_PATH_TO_ROBOT` set to the bound path under `/home/runwhen/collection/`.

- **Runbook**: `codebundles/gh-repo-health/runbook.robot`
- **Monitor**: `codebundles/gh-repo-health/sli.robot`

### Local development (devcontainer only)

`ro` is a dev-time wrapper in `codecollection-devtools` — not the enterprise runtime.

```bash
cd codebundles/gh-repo-health
export GITHUB_REPOS=ALL
export GITHUB_ORGS=my-org
ro runbook.robot
```

### Standalone scripts (no Robot)

Set the input variables above, then run the matching script:

```bash
cd codebundles/gh-repo-health
export GITHUB_REPOS=ALL
export GITHUB_ORGS=my-org
bash check_dormant_repos.sh
```

## Source files

- `runbook.robot` — orchestrates tasks and raises issues
- `sli.robot` — monitor scoring
- `check_dormant_repos.sh` — detect dormant repositories
- `check_stale_issues.sh` — detect stale issue accumulation
- `check_stale_prs.sh` — detect stale pull requests
- `check_branch_hygiene.sh` — audit branch hygiene
- `check_repo_config_health.sh` — audit repository configuration
- `check_release_health.sh` — check release health and cadence
- `check_contributor_pulse.sh` — generate contributor activity pulse