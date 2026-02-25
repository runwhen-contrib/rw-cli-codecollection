# GitHub Actions Health Monitoring

Comprehensive health monitoring for GitHub Actions across specified repositories and organizations.

## Overview

This codebundle provides health monitoring capabilities for GitHub Actions workflows, focusing on:
- Multi-repository analysis across specified repositories or entire organizations
- Multi-organization support for enterprise-wide monitoring
- Workflow failure detection and pattern analysis
- Performance monitoring for long-running workflows
- Security workflow status and vulnerability tracking
- GitHub Actions runner health and utilization across organizations
- Billing and usage monitoring aggregated across organizations
- GitHub API rate limit monitoring
- Service Level Indicator (SLI) calculations for health scoring

## Use Cases

### Multi-Repository Monitoring
Monitor GitHub Actions health across multiple repositories simultaneously, whether specified individually or across entire organizations.

### Multi-Organization Support
- Monitor multiple GitHub organizations simultaneously
- Aggregate health metrics across your entire enterprise
- Compare organization performance and resource utilization
- Centralized monitoring for organizations with distributed teams

### Organization-Wide Health Assessment
Get comprehensive health insights across all repositories in one or more GitHub organizations with configurable limits on the number of repositories analyzed.

### Cross-Organization Repository Selection
- Specify individual repositories from different organizations
- Mix specific repositories with organization-wide analysis
- Flexible scoping for complex enterprise environments

### Failure Pattern Detection
Identify recurring workflow failures across repositories and organizations to detect common patterns that might indicate infrastructure or configuration issues.

### Performance Monitoring
Track workflow performance across repositories and organizations, identifying workflows that consistently run longer than expected thresholds.

### Security Posture Assessment
Monitor security-related workflows (CodeQL, Dependabot, etc.) and track vulnerability status across your entire repository portfolio, spanning multiple organizations.

### Resource Utilization Tracking
Monitor GitHub Actions usage, billing metrics, and runner capacity across multiple organizations to optimize resource allocation and costs.

## Tasks

### Workflow Health Tasks
1. **Check Recent Workflow Failures Across Specified Repositories**
   - Analyzes recent workflow failures across multiple repositories and organizations
   - Identifies failure patterns and provides actionable insights
   - Configurable lookback period

2. **Check Long Running Workflows Across Specified Repositories**
   - Identifies workflows exceeding duration thresholds across repositories and organizations
   - Tracks both in-progress and recently completed long-duration workflows
   - Helps optimize workflow performance

3. **Check Repository Health Summary for Specified Repositories**
   - Provides comprehensive health scoring across repositories and organizations
   - Calculates overall health metrics and failure rates
   - Identifies repositories requiring attention

### Infrastructure Health Tasks
4. **Check GitHub Actions Runner Health Across Specified Organizations**
   - Monitors self-hosted runner availability and status across multiple organizations
   - Tracks runner utilization and capacity aggregated across organizations
   - Alerts on offline or overutilized runners with organization context

5. **Check Security Workflow Status Across Specified Repositories**
   - Monitors security-related workflow execution across repositories and organizations
   - Tracks Dependabot alerts and vulnerability status
   - Identifies critical security issues requiring immediate attention

6. **Check GitHub Actions Billing and Usage Across Specified Organizations**
   - Monitors GitHub Actions usage against included minutes across multiple organizations
   - Aggregates billing metrics and usage patterns
   - Provides early warnings for high usage with organization-level breakdown

7. **Check GitHub API Rate Limits**
   - Monitors API rate limit consumption to prevent throttling during health checks
   - Optimizes API usage patterns across multi-organization monitoring

## Service Level Indicators (SLI)

The SLI calculation provides weighted health scoring across multiple dimensions:

- **Workflow Success Rate** (25%): Overall success rate of workflows across specified repositories and organizations
- **Organization Health** (20%): Health score for organization-wide metrics
- **Security Posture** (20%): Security workflow success and vulnerability status
- **Performance** (15%): Workflow duration and performance metrics
- **Runner Availability** (15%): GitHub Actions runner health and capacity across organizations
- **Rate Limit Management** (5%): API usage efficiency

## Configuration

### Required Configuration

#### Secrets
- `GITHUB_TOKEN`: GitHub Personal Access Token with appropriate permissions
  - Required scopes: `repo`, `actions:read`, `security_events` (for security features)
  - For organization-level features: `read:org`
  - Must have access to all specified organizations

#### Repository Selection
- `GITHUB_REPOS`: Comma-separated list of repositories or 'ALL' for all org repositories
  - Format: `owner/repo1,owner/repo2,owner/repo3` (can span multiple organizations)
  - Example: `microsoft/vscode,github/docs,docker/compose`
  - Use `ALL` to analyze all repositories in the specified organizations
  - Default: `ALL`

#### Organization Selection
- `GITHUB_ORGS`: GitHub organization names (single org or comma-separated list for multiple orgs)
  - Format: `org1,org2,org3` or just `org1` for single organization
  - Example: `microsoft,github,docker` or `microsoft`
  - Required when `GITHUB_REPOS` is 'ALL' or for organization-level checks
  - Supports monitoring single or multiple organizations

### Optional Configuration

#### Thresholds and Limits
- `MAX_WORKFLOW_DURATION_MINUTES`: Maximum expected workflow duration (default: 60)
- `REPO_FAILURE_THRESHOLD`: Maximum failures allowed across repositories (default: 10)
- `HIGH_RUNNER_UTILIZATION_THRESHOLD`: Runner utilization warning threshold % (default: 80)
- `HIGH_USAGE_THRESHOLD`: Billing usage warning threshold % (default: 80)
- `RATE_LIMIT_WARNING_THRESHOLD`: API rate limit warning threshold % (default: 70)
- `MAX_REPOS_TO_ANALYZE`: Maximum repositories to analyze total when using 'ALL' (default: 0 = unlimited)
- `MAX_REPOS_PER_ORG`: Maximum repositories per organization when using 'ALL' (default: 0 = unlimited)

#### Time Windows
- `FAILURE_LOOKBACK_DAYS`: Days to look back for workflow failures (default: 7)
- `SLI_LOOKBACK_DAYS`: Days to look back for SLI calculations (default: 7)

#### SLI Thresholds
- `WORKFLOW_SUCCESS_RATE_THRESHOLD`: Minimum success rate for workflows (default: 0.95)
- `ORG_HEALTH_SCORE_THRESHOLD`: Minimum organization health score (default: 0.90)
- `SECURITY_SCORE_THRESHOLD`: Minimum security score (default: 0.85)
- `PERFORMANCE_SCORE_THRESHOLD`: Minimum performance score (default: 0.80)
- `RUNNER_AVAILABILITY_THRESHOLD`: Minimum runner availability (default: 0.90)

## Examples

### Monitor Specific Repositories Across Organizations
```yaml
GITHUB_REPOS: "microsoft/vscode,github/docs,docker/compose"
GITHUB_ORGS: "microsoft,github,docker"
GITHUB_TOKEN: "ghp_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
```

### Monitor Single Organization
```yaml
GITHUB_REPOS: "ALL"
GITHUB_ORGS: "myorg"
GITHUB_TOKEN: "ghp_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
```

### Monitor Multiple Organizations (Limited per org)
```yaml
GITHUB_REPOS: "ALL"
GITHUB_ORGS: "myorg1,myorg2,myorg3"
MAX_REPOS_PER_ORG: "25"
MAX_REPOS_TO_ANALYZE: "100"
GITHUB_TOKEN: "ghp_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
```

### Enterprise-Wide Monitoring
```yaml
GITHUB_REPOS: "ALL"
GITHUB_ORGS: "corp-frontend,corp-backend,corp-mobile,corp-infrastructure"
MAX_REPOS_PER_ORG: "50"
FAILURE_LOOKBACK_DAYS: "14"
REPO_FAILURE_THRESHOLD: "25"
GITHUB_TOKEN: "ghp_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
```

### Mixed Repository and Organization Monitoring
```yaml
GITHUB_REPOS: "critical-org/app1,critical-org/app2,ALL"
GITHUB_ORGS: "development-org,staging-org"
MAX_REPOS_PER_ORG: "10"
GITHUB_TOKEN: "ghp_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
```

### Custom Thresholds for Enterprise
```yaml
GITHUB_REPOS: "ALL"
GITHUB_ORGS: "myenterprise-dev,myenterprise-prod"
MAX_WORKFLOW_DURATION_MINUTES: "45"
REPO_FAILURE_THRESHOLD: "15"
HIGH_RUNNER_UTILIZATION_THRESHOLD: "70"
FAILURE_LOOKBACK_DAYS: "5"
WORKFLOW_SUCCESS_RATE_THRESHOLD: "0.98"
GITHUB_TOKEN: "ghp_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
```

## Features

### Multi-Organization Support
- Monitor multiple GitHub organizations simultaneously
- Aggregate metrics across your entire enterprise
- Organization-level resource utilization and billing analysis
- Cross-organization repository selection flexibility

### Multi-Repository Support
- Analyze multiple repositories simultaneously
- Organization-wide analysis with configurable limits
- Flexible repository selection (individual repos, entire organizations, or mixed)
- Per-organization repository limits for controlled analysis

### Comprehensive Health Monitoring
- Workflow failure analysis with pattern detection across organizations
- Performance monitoring and bottleneck identification
- Security posture assessment across enterprise
- Resource utilization tracking with organization breakdown

### Intelligent Alerting
- Severity-based issue classification
- Actionable recommendations for each issue
- Threshold-based alerting with customizable limits
- Organization context in issue reporting

### Advanced Analytics
- Weighted SLI scoring across multiple dimensions
- Trend analysis and pattern recognition across organizations
- Performance optimization insights
- Cross-organization comparative analysis

### Rate Limiting Protection
- Built-in GitHub API rate limit monitoring
- Automatic request throttling between organizations
- Optimized API usage patterns for multi-organization monitoring

## Permissions

The GitHub token requires the following permissions for all monitored organizations:
- `repo` - Access to repository data and workflows
- `actions:read` - Read access to GitHub Actions data
- `security_events` - Access to security alerts and advisories (optional, for enhanced security monitoring)
- `read:org` - Organization read access (required for organization-level features)
- `read:billing` - Billing information access (optional, for billing monitoring)

**Note**: The token must have appropriate access to all organizations specified in `GITHUB_ORGS`.

## Troubleshooting

### Common Issues

1. **API Rate Limiting**
   - Reduce `MAX_REPOS_TO_ANALYZE` or `MAX_REPOS_PER_ORG` values
   - Increase the health check interval
   - Use organization-specific token for higher rate limits
   - Consider monitoring organizations separately during high-traffic periods

2. **Access Denied Errors**
   - Verify token has required permissions for all organizations
   - Check repository/organization access across all specified orgs
   - Ensure token hasn't expired
   - Verify organization membership and permissions

3. **High Resource Usage**
   - Limit the number of repositories analyzed per organization
   - Adjust lookback periods based on monitoring needs
   - Optimize API request frequency
   - Consider staging multi-organization monitoring

4. **Slow Performance**
   - Reduce `MAX_REPOS_PER_ORG` for large organizations
   - Decrease lookback periods
   - Consider running checks less frequently
   - Monitor organizations in separate batches if needed

5. **Multi-Organization Complexity**
   - Start with fewer organizations and scale up
   - Use `MAX_REPOS_PER_ORG` to balance coverage and performance
   - Monitor API rate limit usage across organizations
   - Consider separate monitoring for different organization tiers

### Performance Optimization

- Use `MAX_REPOS_PER_ORG` to limit scope for large organizations
- Set `MAX_REPOS_TO_ANALYZE` for overall control across all organizations
- Adjust lookback periods based on your monitoring needs
- Consider separate checks for critical vs. non-critical organizations
- Monitor API rate limit usage and adjust frequency accordingly
- Balance organization coverage with monitoring frequency based on API limits

### Multi-Organization Best Practices

- Start with a small subset of organizations to test configuration
- Use per-organization limits to ensure fair resource distribution
- Monitor API rate limits when adding new organizations
- Consider different monitoring frequencies for different organization types
- Implement tiered monitoring (critical orgs more frequently, others less frequently)
- Use specific repository lists for critical applications across organizations 