# GitHub Repository Health

This codebundle provides comprehensive repository health monitoring across
GitHub organizations — dormant repos, stale issues/PRs, branch hygiene,
config health, release cadence, and contributor activity pulse.

## Tasks

### 1. Detect Dormant Repositories
Finds repositories with no git pushes in the last N days (default: 90). Flags
abandoned or archived repos that may need cleanup.

### 2. Detect Stale Issue Accumulation  
Identifies repos where open issues are stacking up — unassigned, unlabeled,
unresponded, or just untouched for too long. Surfaces issues where the
original author is still waiting for a team response.

### 3. Detect Stale Pull Requests
Finds PRs that have been open too long, lack reviews, or have merge conflicts.
Shows exactly who is blocking whom.

### 4. Audit Branch Hygiene
Finds stale branches — branches not touched in N days (excluding default
and protected branches) that likely need cleanup.

### 5. Audit Repository Configuration Health
Checks for essential project files (README, LICENSE, CONTRIBUTING, CODEOWNERS),
branch protection rules, and GitHub community profile scores.

### 6. Check Release Health and Cadence
Checks release frequency, identifies repos with no releases, and flags
overdue releases based on accumulated unreleased commits.

### 7. Generate Contributor Activity Pulse
Builds a per-person activity summary across the org — who committed, who
opened PRs, and critically who is waiting on whom for reviews.

## Configuration

### Required Secrets

| Secret | Description | Required |
|---|---|---|
| `GITHUB_TOKEN` | GitHub Personal Access Token | no (if using GitHub App) |
| `GITHUB_APP_ID` | GitHub App ID | no (if using PAT) |
| `GITHUB_APP_INSTALLATION_ID` | GitHub App Installation ID (auto-discovered if unset) | no |
| `GITHUB_APP_CLIENT_ID` | GitHub App Client ID (used to auto-discover installation) | no |
| `GITHUB_APP_PRIVATE_KEY` | GitHub App Private Key (PEM) | no (if using PAT) || no (if using PAT) |

> Either `GITHUB_TOKEN` **or** all three GitHub App credentials must be provided.

### Repository and Organization Selection

| Variable | Description | Default |
|---|---|---|
| `GITHUB_REPOS` | Comma-separated repos (owner/repo) or `ALL` | `ALL` |
| `GITHUB_ORGS` | Organization names (comma-separated) | `""` |

### Thresholds

| Variable | Description | Default |
|---|---|---|
| `DORMANT_DAYS` | Days without push before dormant | `90` |
| `STALE_ISSUE_DAYS` | Days without update before stale issue | `60` |
| `STALE_ISSUE_THRESHOLD` | Total stale issues alert threshold | `20` |
| `STALE_PR_DAYS` | Days open before stale PR | `14` |
| `STALE_BRANCH_DAYS` | Days since commit before stale branch | `60` |
| `OVERDUE_COMMIT_THRESHOLD` | Unreleased commits before release overdue | `30` |
| `PULSE_DAYS` | Days to look back for contributor pulse | `7` |
| `MAX_REPOS_TO_ANALYZE` | Max repos total (0 = unlimited) | `0` |
| `MAX_REPOS_PER_ORG` | Max repos per org (0 = unlimited) | `0` |

### Required Permissions

- `repo` scope (or repository read access for GitHub Apps)
- `read:org` for organization-level data
- `issues:read` for issue tracking
- `pull_requests:read` for PR data

## SLI

The SLI monitor calculates a composite health score (0.0–1.0) from:

- **Dormant repos** (15%): Ratio of active vs dormant repositories
- **Issue health** (20%): Stale and unresponded issue ratio
- **PR health** (20%): Stale PR ratio
- **Config health** (20%): Repository best-practices compliance
- **Release health** (25%): Release cadence and overdue releases

## Recommended Interval

- **Runbook**: 1/day (comprehensive daily health pulse)
- **Monitor**: 4–6 hours