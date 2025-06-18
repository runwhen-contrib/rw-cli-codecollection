# Azure DevOps Project Health

This codebundle monitors Azure DevOps project health across multiple projects, identifying issues with pipelines, agent pools, repository policies, and service connections.

## Tasks

### Check Agent Pool Availability for Organization
- **What it checks**: Agent pool health, offline agents, capacity issues
- **Severity levels**: 
  - Sev 3: Offline agents, authentication failures
  - Sev 4: Disabled agents (informational)

### Check for Failed Pipelines Across Projects  
- **What it checks**: Recent pipeline failures with detailed logs
- **Severity levels**: Sev 3 for all pipeline failures

### Check for Long-Running Pipelines
- **What it checks**: Pipelines exceeding duration thresholds
- **Severity levels**: Sev 3 for pipelines over threshold
- **Default threshold**: 60m (configurable)

### Check for Queued Pipelines
- **What it checks**: Pipelines queued beyond threshold limits
- **Severity levels**: Sev 3 for pipelines queued too long  
- **Default threshold**: 30m (configurable)

### Check Repository Branch Policies
- **What it checks**: Branch policy compliance against standards
- **Severity levels**: 
  - Sev 2: Policy violations
  - Sev 3: Access/permission issues

### Check Service Connection Health
- **What it checks**: Service connection availability and readiness
- **Severity levels**: Sev 3 for connection issues

### Investigate Pipeline Performance Issues
- **What it checks**: Performance trends and bottlenecks
- **Severity levels**: Based on performance degradation severity

## Configuration Variables

| Variable | Description | Default | Required |
|----------|-------------|---------|----------|
| `AZURE_DEVOPS_ORG` | Azure DevOps organization name | - | Yes |
| `AZURE_DEVOPS_PROJECTS` | Comma-separated list of projects | - | Yes |
| `DURATION_THRESHOLD` | Long-running pipeline threshold | 60m | No |
| `QUEUE_THRESHOLD` | Queued pipeline threshold | 30m | No |

## Authentication

Supports two authentication methods:

### Service Principal (Recommended)
```bash
# Set via Azure CLI login
az login --service-principal -u <client-id> -p <client-secret> --tenant <tenant-id>
```

### Personal Access Token
```bash
export AZURE_DEVOPS_PAT="your-pat-token"
export AUTH_TYPE="pat"
```

## Usage Examples

### Single Project
```yaml
variables:
  AZURE_DEVOPS_ORG: "contoso"
  AZURE_DEVOPS_PROJECTS: "frontend-app"
```

### Multiple Projects
```yaml
variables:
  AZURE_DEVOPS_ORG: "contoso" 
  AZURE_DEVOPS_PROJECTS: "frontend-app,backend-api,data-service"
  DURATION_THRESHOLD: "45m"
  QUEUE_THRESHOLD: "20m"
```

## Severity Levels

- **Sev 1**: Critical issues requiring immediate attention
- **Sev 2**: Major issues affecting functionality  
- **Sev 3**: Errors that need investigation
- **Sev 4**: Informational items for awareness

## Permissions Required

- **Project-level**: Read access to pipelines, repositories, service connections
- **Organization-level**: Read access to agent pools
- **Repository-level**: Read access to policies and branches

## Troubleshooting

### Authentication Issues
- Verify service principal has required permissions
- Check PAT token has appropriate scopes
- Ensure organization name is correct

### Permission Errors  
- Grant "Project Reader" role minimum
- For agent pools: "Agent Pool Reader" role
- For policies: "Repository Reader" role

### No Issues Found
This is normal when all systems are healthy. The runbook only reports actual problems, not healthy states.
