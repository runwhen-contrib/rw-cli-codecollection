# Azure DevOps Repository Health

This codebundle provides comprehensive repository-level health monitoring for Azure DevOps, focusing on identifying root causes of repository issues and misconfigurations that impact development workflows. It includes specific tasks for troubleshooting failing applications by analyzing recent code changes and pipeline failures.

## Overview

The Azure DevOps Repository Health codebundle monitors:
- **Security Configuration**: Branch policies, access controls, and security misconfigurations
- **Code Quality**: Technical debt, maintainability issues, and quality metrics
- **Branch Management**: Branch structure, naming conventions, and workflow patterns
- **Collaboration Health**: Pull request patterns, code review practices, and team collaboration
- **Performance Issues**: Repository size, storage optimization, and performance bottlenecks
- **Critical Issues**: Deep investigation when security or configuration problems are detected
- **Application Troubleshooting**: Recent code changes and pipeline failures that may cause application issues

## Use Cases

- **Security Auditing**: Identify security misconfigurations and policy violations
- **Code Quality Assessment**: Detect technical debt and maintainability issues
- **Workflow Optimization**: Analyze collaboration patterns and identify bottlenecks
- **Performance Troubleshooting**: Find repository performance issues and optimization opportunities
- **Incident Response**: Investigate security incidents and configuration problems
- **Application Failure Troubleshooting**: Analyze recent changes and pipeline failures when applications crash or fail

## Configuration

### Required Variables

- `AZURE_DEVOPS_ORG`: Your Azure DevOps organization name
- `AZURE_DEVOPS_PROJECT`: Azure DevOps project name
- `AZURE_DEVOPS_REPO`: Repository name to analyze
- `AZURE_RESOURCE_GROUP`: Azure resource group
- `azure_credentials`: Secret containing Azure service principal credentials

### Optional Variables

- `REPO_SIZE_THRESHOLD_MB`: Repository size threshold in MB (default: 500)
- `STALE_BRANCH_DAYS`: Days after which branches are considered stale (default: 90)
- `MIN_CODE_COVERAGE`: Minimum code coverage percentage threshold (default: 80)
- `ANALYSIS_DAYS`: Number of days to look back for recent changes and pipeline failures analysis (default: 7)

### Azure Credentials Secret

The `azure_credentials` secret should contain:
```json
{
  "AZURE_CLIENT_ID": "your-service-principal-client-id",
  "AZURE_TENANT_ID": "your-azure-tenant-id", 
  "AZURE_CLIENT_SECRET": "your-service-principal-secret",
  "AZURE_SUBSCRIPTION_ID": "your-azure-subscription-id"
}
```

## Required Permissions

The service principal needs the following permissions:
- **Repository**: Read access to repository information and statistics
- **Branch Policies**: Read access to branch protection policies
- **Pull Requests**: Read access to pull request information
- **Build Pipelines**: Read access to build definitions and results
- **Security**: Read access to repository permissions and security settings

## Tasks Overview

### Investigate Recent Code Changes (Application Troubleshooting)
Analyzes recent commits, releases, and code changes in the configurable analysis period to identify changes that might be causing application failures. Flags emergency commits, configuration changes, large commits, and high-frequency commit patterns.

### Analyze Pipeline Failures (Application Troubleshooting) 
Investigates recent CI/CD pipeline failures for the repository to identify deployment issues, test failures, and build problems that may correlate with application issues. Categorizes failures and provides actionable troubleshooting guidance.

### Calculate Repository Health Score
Calculates an overall repository health score (0-100) based on security, quality, configuration, and collaboration metrics.

### Analyze Repository Security Configuration
- **Branch Protection**: Checks for missing or weak branch policies
- **Access Controls**: Reviews repository permissions and access patterns
- **Security Policies**: Identifies policy violations and misconfigurations
- **Default Branch**: Verifies default branch protection and naming

### Detect Code Quality Issues and Technical Debt
- **Build Analysis**: Reviews build failure patterns and performance
- **Testing Coverage**: Checks for test automation and coverage
- **Repository Structure**: Analyzes naming conventions and organization
- **Technical Debt**: Identifies maintainability and quality issues

### Identify Branch Management Problems
- **Branch Structure**: Analyzes branch naming and organization patterns
- **Stale Branches**: Identifies abandoned or outdated branches
- **Workflow Patterns**: Checks for Git workflow compliance
- **Branch Policies**: Verifies protection across important branches

### Analyze Pull Request and Collaboration Patterns
- **Review Practices**: Examines code review quality and patterns
- **Collaboration Health**: Identifies team workflow bottlenecks
- **PR Lifecycle**: Analyzes pull request completion and abandonment rates
- **Contributor Patterns**: Reviews team participation and knowledge sharing

### Check Repository Performance and Size Issues
- **Storage Optimization**: Identifies large files and Git LFS opportunities
- **Performance Impact**: Analyzes factors affecting clone and fetch performance
- **Build Performance**: Correlates repository characteristics with build times
- **Cleanup Opportunities**: Suggests repository maintenance actions

### Investigate Critical Repository Issues
- **Security Investigation**: Deep dive into security misconfigurations
- **Configuration Analysis**: Comprehensive policy and permission review
- **Incident Response**: Provides detailed troubleshooting information
- **Remediation Guidance**: Specific steps to address critical issues

## Health Score Calculation

The repository health score is calculated based on:
- **Security Issues** (weighted 20 points each): Branch protection, access controls
- **Quality Issues** (weighted 10 points each): Code quality, technical debt
- **Configuration Issues** (weighted 5 points each): Branch management, policies
- **Collaboration Issues** (weighted 3 points each): PR patterns, team workflow

Score ranges:
- **90-100**: Excellent repository health
- **70-89**: Good health with minor issues
- **50-69**: Fair health with notable problems
- **Below 50**: Poor health requiring immediate attention

## Root Cause Analysis Focus

This codebundle specifically identifies root causes of common issues:

### Security Problems
- **Missing branch protection** → Direct commits to main branch
- **Weak review policies** → Code quality and security risks
- **Over-permissioning** → Unauthorized access and changes
- **Self-approvals** → Reduced review effectiveness

### Quality Issues
- **No build validation** → Untested code in main branch
- **High failure rates** → Technical debt and instability
- **Large repository size** → Performance and maintenance problems
- **Poor naming conventions** → Team confusion and workflow issues

### Collaboration Problems
- **High PR abandonment** → Workflow or tooling issues
- **Long-lived PRs** → Review bottlenecks or scope problems
- **Single reviewers** → Knowledge concentration and bottlenecks
- **Quick merges** → Insufficient review time

### Performance Issues
- **Large files without LFS** → Slow clones and fetches
- **Excessive branches** → Repository bloat and confusion
- **Frequent small pushes** → Workflow inefficiency

## Troubleshooting

### Common Root Causes and Solutions

1. **Unprotected Default Branch**
   - **Root Cause**: Missing branch protection policies
   - **Solution**: Implement required reviewers and build validation
   - **Prevention**: Establish branch protection as part of repository setup

2. **High Build Failure Rate**
   - **Root Cause**: Poor code quality or inadequate testing
   - **Solution**: Improve test coverage and code quality gates
   - **Prevention**: Implement pre-commit hooks and quality standards

3. **Repository Performance Issues**
   - **Root Cause**: Large files or excessive history
   - **Solution**: Implement Git LFS and repository cleanup
   - **Prevention**: Establish file size policies and regular maintenance

4. **Poor Collaboration Patterns**
   - **Root Cause**: Inadequate review process or team practices
   - **Solution**: Establish review guidelines and team training
   - **Prevention**: Regular team retrospectives and process improvement

## Integration

This codebundle complements:
- **azure-devops-project-health**: Project-level pipeline and overall health
- **azure-devops-organization-health**: Organization-wide platform monitoring
- **Security scanning tools**: Detailed code and dependency analysis

Use together for comprehensive Azure DevOps monitoring across all levels.

## Output

The codebundle generates:
- Repository health score and detailed metrics
- Security configuration analysis with specific remediation steps
- Code quality assessment with technical debt identification
- Branch management recommendations and cleanup suggestions
- Collaboration pattern analysis with workflow improvements
- Performance optimization recommendations
- Critical issue investigation reports when problems are detected 