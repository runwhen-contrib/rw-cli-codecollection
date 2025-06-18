# Azure DevOps Organization Health Monitoring

This codebundle provides comprehensive health monitoring for Azure DevOps organizations, focusing on platform-wide issues, shared resources, and organizational capacity management.

## Overview

The runbook performs seven key monitoring tasks that analyze different aspects of your Azure DevOps organization's health, from basic connectivity to complex cross-project dependencies. Each task is designed to identify specific issues and provide actionable recommendations.

## Authentication Requirements

This codebundle supports two authentication methods:

### Service Principal (Recommended)
- Requires: `AZURE_CLIENT_ID`, `AZURE_CLIENT_SECRET`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`
- Provides: Comprehensive access to Azure DevOps APIs
- Best for: Production monitoring and automated scenarios

### Personal Access Token (PAT)
- Requires: `AZURE_DEVOPS_PAT` with appropriate scopes
- Provides: User-level access to Azure DevOps APIs  
- Best for: Development and manual testing

## Detailed Task Documentation

### 1. Check Service Health Status

**Purpose**: Tests connectivity and access to core Azure DevOps APIs and services.

**Specific Checks**:
- Tests basic connectivity to organization URL and API endpoints
- Validates access to projects API (lists all projects in organization)  
- Checks agent pools API availability (lists all agent pools)
- Tests service connections API using a sample project
- Monitors API response times and detects rate limiting
- Attempts to access organization-level settings (may require additional permissions)
- Reports on overall organization connectivity and API health

**Issue Severity Levels**:
- **Severity 1 (Critical)**: Complete service unavailability
- **Severity 2 (Major)**: Slow API responses or rate limiting detected
- **Severity 3 (Error)**: API endpoint failures or connectivity issues
- **Severity 4 (Informational)**: Limited organization access due to permissions

**Requirements**: Basic read access to projects and agent pools

---

### 2. Check Agent Pool Capacity and Utilization

**Purpose**: Analyzes self-hosted agent pools for capacity issues including offline agents, utilization thresholds, and configuration problems.

**Specific Checks**:
- Enumerates all agent pools (excludes Microsoft-hosted pools)
- For each pool, counts total agents, online agents, offline agents, and busy agents
- Calculates utilization percentage (busy agents / online agents)
- Identifies pools with no agents configured
- Detects pools where all agents are offline
- Flags pools with utilization above threshold (default 80%)
- Reports pools with low capacity (only 1 agent online)
- Calculates high offline ratios (>50% agents offline)
- Provides organization-wide capacity summary and recommendations

**Issue Severity Levels**:
- **Severity 1 (Critical)**: Complete agent pool unavailability
- **Severity 2 (Major)**: High utilization (>80%), all agents offline, high offline ratio
- **Severity 3 (Error)**: No agents configured in pool

**Configuration**:
- `AGENT_UTILIZATION_THRESHOLD`: Percentage threshold for flagging high utilization (default: 80)

**Requirements**: Read access to agent pools and agents

---

### 3. Validate Organization Policies and Security Settings

**Purpose**: Examines organization security groups, user access levels, and policy configurations.

**Specific Checks**:
- Attempts to enumerate organization security groups and membership
- Lists all users in the organization with their access levels
- Checks for organization-level policy configurations
- Validates security group assignments and permissions
- Reports on user access distribution and potential security issues
- Identifies missing or misconfigured security policies

**Issue Severity Levels**:
- **Severity 1 (Critical)**: Critical security vulnerabilities
- **Severity 2 (Major)**: Security policy misconfigurations
- **Severity 3 (Error)**: Missing required security groups or policies

**Requirements**: Organization Administrator permissions for full analysis

**Note**: Many organization-level security checks require elevated permissions. Limited information available with basic permissions.

---

### 4. Check License Utilization and Capacity

**Purpose**: Analyzes user license assignments for cost optimization opportunities and identifies inactive users or licensing inefficiencies.

**Specific Checks**:
- Retrieves all users in the organization with their license types
- Categorizes users by license level: Basic, Stakeholder, Visual Studio Subscriber, Express, Advanced
- Calculates estimated monthly licensing costs based on current assignments
- Identifies users inactive for 90+ days (candidates for license removal)
- Detects high ratios of Basic users (>80%) that might indicate over-licensing
- Flags organizations with no Stakeholder users (missed cost savings opportunity)
- Checks for missing Visual Studio Subscriber benefits utilization
- Provides cost optimization recommendations and inactive user cleanup suggestions

**Issue Severity Levels**:
- **Severity 1 (Critical)**: Licensing compliance issues
- **Severity 2 (Major)**: High percentage of inactive users or inefficient licensing
- **Severity 4 (Informational)**: License optimization opportunities

**Configuration**:
- `LICENSE_UTILIZATION_THRESHOLD`: Percentage threshold for flagging licensing issues (default: 90)

**Requirements**: User Entitlements read access

**Note**: Only reports issues when actual licensing problems are detected (not for optimal configurations)

---

### 5. Investigate Platform-wide Service Incidents

**Purpose**: Monitors Azure DevOps platform status and detects service-wide incidents by checking official status pages and API performance.

**Specific Checks**:
- Tests connectivity to organization URL and measures response times
- Retrieves and parses Azure DevOps status page (status.dev.azure.com)
- Analyzes service health status from official Azure DevOps status API
- Validates Azure CLI authentication and measures authentication performance
- Tests key API endpoints (/projects, /distributedtask/pools) for availability
- Checks Azure DevOps specific connectivity (dev.azure.com, status.dev.azure.com)
- Detects slow authentication (>10s threshold)
- Identifies API endpoint failures or slow responses (>10s)
- Reports service degradation based on official health status

**Issue Severity Levels**:
- **Severity 1 (Critical)**: Complete platform unavailability
- **Severity 2 (Major)**: Slow authentication or API responses
- **Severity 3 (Error)**: Service degradation reported by Azure DevOps status

**Requirements**: Internet access to Azure DevOps status pages

**Note**: Only reports issues when actual platform incidents are detected (not for healthy services)

---

### 6. Analyze Cross-Project Dependencies

**Purpose**: Identifies shared resources between projects including agent pools, service connections, and potential naming conflicts.

**Specific Checks**:
- Analyzes shared agent pool usage across all projects
- Identifies agent pools used by multiple projects
- Checks for duplicate service connections with similar names
- Analyzes repository dependencies and cross-project references
- Examines pipeline configurations for cross-project dependencies
- Identifies projects with similar naming patterns (potential organizational issues)
- Reports on shared resource utilization and potential conflicts

**Issue Severity Levels**:
- **Severity 2 (Major)**: Duplicate service connections across projects
- **Severity 3 (Error)**: Excessive shared resource dependencies (>10 shared pools)
- **Severity 4 (Informational)**: Similar project naming patterns

**Requirements**: Read access to projects, repositories, pipelines, and service connections

**Note**: Shared agent pools are normal and only flagged when excessive (indicating poor organization)

---

### 7. Investigate Platform Issues

**Purpose**: Performs detailed investigation of agent pool issues and analyzes recent pipeline failures across all projects.

**Specific Checks**:
- Deep analysis of problematic agent pools identified in previous tasks
- Investigates specific agent pool configurations and issues
- Analyzes recent pipeline failures across all projects
- Correlates agent pool issues with pipeline failure patterns
- Identifies systemic issues affecting multiple projects
- Provides detailed recommendations for platform improvements

**Issue Severity Levels**:
- **Severity 1 (Critical)**: Platform-wide failures
- **Severity 2 (Major)**: Recurring platform issues affecting multiple projects
- **Severity 3 (Error)**: Systemic platform problems
- **Severity 4 (Informational)**: Performance optimization opportunities

**Requirements**: Read access to pipelines, builds, and agent pools across all projects

## Configuration Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `AZURE_DEVOPS_ORG` | Required | Azure DevOps organization name |
| `AGENT_UTILIZATION_THRESHOLD` | 80 | Agent pool utilization threshold (0-100%) |
| `LICENSE_UTILIZATION_THRESHOLD` | 90 | License utilization threshold (0-100%) |

## Issue Severity Scale

This codebundle uses a 4-level severity scale:

- **Severity 1 (Critical)**: Complete service failures or critical security issues
- **Severity 2 (Major)**: Issues that impact performance or efficiency but don't prevent operation  
- **Severity 3 (Error)**: Problems that prevent normal operation or indicate misconfigurations
- **Severity 4 (Informational)**: Optimization opportunities, recommendations, or minor issues

## Permissions Required

### Minimum Permissions
- **Project Reader**: Basic project and repository access
- **Agent Pool Reader**: View agent pools and agents
- **Service Connection Reader**: View service connections

### Recommended Permissions
- **Project Collection Administrator**: Full organization access
- **Organization Administrator**: Access to organization-level settings and policies
- **User Entitlements Administrator**: License management and user access

### Permission Limitations
Some tasks will report limited information or permission-related warnings when run with insufficient privileges. This is normal and expected behavior.

## Output and Reporting

Each task generates:
- **Console Output**: Real-time progress and summary information
- **JSON Files**: Structured issue data for programmatic processing
- **Issues**: Actionable items with severity levels and next steps
- **Reports**: Detailed analysis results and recommendations

## Troubleshooting

### Common Issues

1. **Authentication Failures**: Verify service principal credentials or PAT permissions
2. **Permission Errors**: Some tasks require elevated organization permissions
3. **API Rate Limiting**: Large organizations may hit API limits during analysis
4. **Timeout Issues**: Increase timeout values for organizations with many projects

### Debug Information

Enable debug logging by setting appropriate log levels in the Robot Framework execution environment.

## Integration

This codebundle complements:
- **azure-devops-project-health**: Project-specific health monitoring
- **azure-devops-pipeline-health**: Pipeline-focused diagnostics
- **azure-devops-repository-health**: Repository and code quality monitoring

Use together for comprehensive Azure DevOps monitoring across all organizational levels.

## Output

The codebundle generates:
- Organization health score and metrics
- Detailed issue reports with severity levels
- Capacity and utilization analysis
- Policy compliance status
- License optimization recommendations
- Platform investigation results when issues are detected 