# Azure DevOps Organization Health

This codebundle provides comprehensive organization-level health monitoring for Azure DevOps, focusing on platform-wide issues and shared resources that affect multiple projects.

## Overview

The Azure DevOps Organization Health codebundle monitors:
- **Service Health**: Overall Azure DevOps service availability and performance
- **Agent Pool Capacity**: Organization-wide agent pool utilization and capacity issues
- **Policies & Compliance**: Organization-level security policies and compliance status
- **License Utilization**: License usage patterns and optimization opportunities
- **Cross-Project Dependencies**: Shared resources and inter-project dependencies
- **Platform Issues**: Deep investigation when platform-wide problems are detected

## Use Cases

- **Platform Operations**: Monitor organization-wide Azure DevOps health
- **Capacity Planning**: Track agent pool utilization and licensing needs
- **Security Compliance**: Verify organization policies and security settings
- **Cost Optimization**: Identify license optimization opportunities
- **Incident Response**: Correlate local issues with platform-wide problems

## Configuration

### Required Variables

- `AZURE_DEVOPS_ORG`: Your Azure DevOps organization name
- `AZURE_RESOURCE_GROUP`: Azure resource group for the organization
- `azure_credentials`: Secret containing Azure service principal credentials

### Optional Variables

- `AGENT_UTILIZATION_THRESHOLD`: Agent pool utilization threshold (default: 80%)
- `LICENSE_UTILIZATION_THRESHOLD`: License utilization threshold (default: 90%)

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
- **Azure DevOps**: Organization-level read access
- **Agent Pools**: Read access to all agent pools
- **Security**: Read access to organization security settings
- **Users**: Read access to user and licensing information
- **Projects**: Read access to all projects for cross-project analysis

## Tasks Overview

### Calculate Organization Health Score
Calculates an overall organization health score (0-100) based on detected issues across all monitoring areas.

### Check Organization Service Health
- Tests basic Azure DevOps service connectivity
- Verifies API accessibility and response times
- Checks for service-level issues

### Check Agent Pool Capacity and Distribution
- Analyzes all agent pools in the organization
- Monitors capacity, utilization, and availability
- Identifies capacity bottlenecks and distribution issues
- Flags pools with high utilization or offline agents

### Check Organization-Level Policies and Compliance
- Reviews organization security policies
- Checks user access levels and permissions
- Verifies project visibility settings
- Analyzes branch protection policies across projects

### Monitor License Utilization and Capacity
- Analyzes license distribution across user types
- Identifies inactive users and optimization opportunities
- Estimates licensing costs
- Flags unusual usage patterns

### Check Cross-Project Dependencies and Shared Resources
- Analyzes shared agent pool usage
- Identifies duplicate service connections
- Checks for cross-project repository dependencies
- Reviews project organization patterns

### Investigate Platform-Wide Issues
- Performs deep investigation when issues are detected
- Correlates problems across different services
- Analyzes recent failures across projects
- Checks for authentication and connectivity issues

## Health Score Calculation

The organization health score is calculated based on:
- **Agent Pool Issues**: Capacity problems, offline agents
- **Security Issues**: Policy violations, compliance problems  
- **License Issues**: Over-utilization, inactive users
- **Platform Issues**: Service connectivity, performance problems

Score ranges:
- **90-100**: Excellent health
- **70-89**: Good health with minor issues
- **50-69**: Fair health with notable issues
- **Below 50**: Poor health requiring immediate attention

## Troubleshooting

### Common Issues

1. **Permission Errors**
   - Verify service principal has organization-level permissions
   - Check Azure DevOps security group membership

2. **Agent Pool Access Issues**
   - Ensure service principal can read agent pool information
   - Verify agent pool security settings

3. **License Information Unavailable**
   - Check user management permissions
   - Verify access to organization billing information

4. **Slow Performance**
   - Monitor Azure DevOps service status
   - Check network connectivity and latency

### Investigation Steps

When platform issues are detected:
1. Review service health status
2. Check agent pool capacity and distribution
3. Verify organization policies and compliance
4. Analyze license utilization patterns
5. Investigate cross-project dependencies
6. Perform deep platform investigation
7. Check for service incidents or outages

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