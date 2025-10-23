# Git Repository Health Monitoring

Comprehensive health monitoring for Git repositories across specified repositories and organizations.

## Overview

This codebundle provides health monitoring capabilities for Git repositories, focusing on:
- Multi-repository analysis across specified repositories or entire organizations
- Multi-organization support for enterprise-wide monitoring
- Recent commit activity and patterns analysis
- Repository health metrics including commit frequency, contributor activity, and branch health
- Code quality indicators through commit message analysis
- Repository maintenance status and staleness detection
- GitHub API rate limit monitoring
- Service Level Indicator (SLI) calculations for repository health scoring

## Use Cases

### Multi-Repository Monitoring
Monitor Git repository health across multiple repositories simultaneously, whether specified individually or across entire organizations.

### Multi-Organization Support
- Monitor multiple GitHub organizations simultaneously
- Aggregate health metrics across your entire enterprise
- Compare organization performance and repository activity
- Centralized monitoring for organizations with distributed teams

### Organization-Wide Health Assessment
Get comprehensive health insights across all repositories in one or more GitHub organizations with configurable limits on the number of repositories analyzed.

### Cross-Organization Repository Selection
- Specify individual repositories from different organizations
- Mix specific repositories with organization-wide analysis
- Flexible scoping for complex enterprise environments

### Recent Commit Analysis
Track recent commit activity across repositories and organizations, identifying repositories with:
- High commit frequency indicating active development
- Low commit frequency that might indicate stale or abandoned projects
- Commit message quality and consistency patterns
- Contributor diversity and activity levels

### Repository Health Assessment
Monitor repository health indicators including:
- Days since last commit
- Number of active contributors
- Branch management patterns
- Repository size and growth trends
- Issue and pull request activity correlation

## Configuration

### Environment Variables

#### Repository Selection
- `GITHUB_REPOS`: Comma-separated list of repositories (format: `owner/repo`) or `ALL` for organization-wide analysis
- `GITHUB_ORGS`: GitHub organization names (single org or comma-separated list for multiple orgs)

#### Analysis Parameters
- `COMMIT_LOOKBACK_DAYS`: Number of days to look back for commit analysis (default: 30)
- `STALE_REPO_THRESHOLD_DAYS`: Number of days without commits to consider a repository stale (default: 90)
- `MIN_COMMITS_HEALTHY`: Minimum number of commits in the lookback period for a healthy repository (default: 5)
- `MAX_REPOS_TO_ANALYZE`: Maximum number of repositories to analyze (default: 50)
- `MAX_REPOS_PER_ORG`: Maximum number of repositories per organization (default: 20)

#### Health Scoring Thresholds
- `MIN_REPO_HEALTH_SCORE`: Minimum acceptable repository health score (default: 0.7)
- `MIN_COMMIT_FREQUENCY_SCORE`: Minimum acceptable commit frequency score (default: 0.6)
- `MIN_CONTRIBUTOR_DIVERSITY_SCORE`: Minimum acceptable contributor diversity score (default: 0.5)
- `MAX_STALE_REPOS_PERCENTAGE`: Maximum percentage of stale repositories considered healthy (default: 20)

### Authentication
- `GITHUB_TOKEN`: GitHub Personal Access Token with repository read permissions

## Metrics and Health Indicators

### Repository Health Score
Composite score based on:
- **Commit Activity (40%)**: Recent commit frequency and consistency
- **Contributor Diversity (25%)**: Number of unique contributors and distribution of commits
- **Repository Freshness (20%)**: Time since last commit and regular activity patterns
- **Code Quality Indicators (15%)**: Commit message quality and branch management

### Key Metrics
- **Recent Commits**: Number and frequency of commits in the specified lookback period
- **Active Contributors**: Number of unique contributors in the recent period
- **Repository Staleness**: Days since last commit
- **Commit Message Quality**: Analysis of commit message patterns and consistency
- **Branch Activity**: Analysis of branch creation, merging, and management patterns

## Output Format

### Runbook Tasks
1. **Analyze Recent Commits Across Repositories**: Detailed analysis of recent commit activity
2. **Check Repository Health Summary**: Overall health assessment across all specified repositories
3. **Identify Stale Repositories**: Detection of repositories with low activity
4. **Analyze Contributor Activity**: Assessment of contributor diversity and activity patterns
5. **Check Repository Maintenance Status**: Analysis of repository maintenance indicators

### SLI Metrics
- Repository Health Score (0-1)
- Commit Frequency Score (0-1)
- Contributor Diversity Score (0-1)
- Repository Freshness Score (0-1)

## Example Usage

### Monitor Specific Repositories
```yaml
GITHUB_REPOS: "microsoft/vscode,microsoft/typescript,facebook/react"
COMMIT_LOOKBACK_DAYS: "30"
MIN_COMMITS_HEALTHY: "10"
```

### Monitor Entire Organization
```yaml
GITHUB_REPOS: "ALL"
GITHUB_ORGS: "microsoft"
MAX_REPOS_PER_ORG: "25"
STALE_REPO_THRESHOLD_DAYS: "60"
```

### Multi-Organization Monitoring
```yaml
GITHUB_REPOS: "ALL"
GITHUB_ORGS: "microsoft,github,facebook"
MAX_REPOS_TO_ANALYZE: "100"
COMMIT_LOOKBACK_DAYS: "14"
```

## Health Scoring Algorithm

The repository health score is calculated using a weighted average of multiple factors:

1. **Commit Activity Score**: Based on commit frequency and consistency over the lookback period
2. **Contributor Diversity Score**: Based on the number of unique contributors and distribution of their contributions
3. **Freshness Score**: Based on how recently the repository was updated
4. **Quality Score**: Based on commit message patterns, branch management, and other quality indicators

Each repository receives a score between 0 and 1, with 1 being the healthiest. The overall health score aggregates individual repository scores across the entire scope of analysis.

## Limitations

- Requires GitHub Personal Access Token with appropriate repository permissions
- API rate limits may affect analysis of large numbers of repositories
- Private repositories require token with private repository access
- Analysis depth is limited by GitHub API response sizes and rate limits
