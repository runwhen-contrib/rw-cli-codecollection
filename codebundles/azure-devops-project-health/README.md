# Azure DevOps Project Health

This codebundle provides comprehensive Azure DevOps project health monitoring with intelligent conditional investigation. It combines basic health checks with deep investigation capabilities that are triggered only when issues are detected.

## Features

### Core Health Monitoring
- **Agent Pool Availability** (Organization-level)
- **Pipeline Health** (Failed, Long-Running, Queued)
- **Repository Policy Compliance**
- **Service Connection Health**
- **Multi-Project Support**

### Intelligent Investigation (Conditional)
- **Pipeline Failure Root Cause Analysis** - Deep dive into failures with commit correlation
- **Repository Health Analysis** - Commit patterns, branch health, PR status
- **Performance Trend Analysis** - Bottleneck identification and optimization insights
- **Health Score Calculation** - SLI-based triggering of investigations

### Smart Execution
- **Basic checks always run** - Fast, lightweight monitoring
- **Deep investigation triggered conditionally** - Only when health issues are detected
- **Resource efficient** - Expensive analysis only when needed
- **Comprehensive reporting** - Detailed insights when problems occur

## Configuration

The runbook requires initialization with the following variables:

- `AZURE_RESOURCE_GROUP`: The Azure resource group where DevOps resources are deployed
- `AZURE_DEVOPS_ORG`: Your Azure DevOps organization name
- `AZURE_DEVOPS_PROJECTS`: Comma-separated list of Azure DevOps projects to monitor
- `DURATION_THRESHOLD`: Threshold for long-running pipelines (format: 60m, 2h) (default: 60m)
- `QUEUE_THRESHOLD`: Threshold for queued pipelines (format: 10m, 1h) (default: 30m)
- `INVESTIGATION_THRESHOLD`: Health score threshold for triggering deep investigation (0-100) (default: 90)

## Usage Examples

### Single Project Monitoring
```yaml
variables:
  AZURE_DEVOPS_ORG: "contoso"
  AZURE_DEVOPS_PROJECTS: "frontend-app"
  DURATION_THRESHOLD: "30m"
  QUEUE_THRESHOLD: "15m"
  INVESTIGATION_THRESHOLD: "85"
```

### Multi-Project Team Monitoring
```yaml
variables:
  AZURE_DEVOPS_ORG: "contoso"
  AZURE_DEVOPS_PROJECTS: "frontend-app,backend-api,data-service"
  DURATION_THRESHOLD: "60m"
  QUEUE_THRESHOLD: "30m"
  INVESTIGATION_THRESHOLD: "90"
```

### High-Sensitivity Monitoring
```yaml
variables:
  AZURE_DEVOPS_ORG: "contoso"
  AZURE_DEVOPS_PROJECTS: "critical-service,payment-api"
  DURATION_THRESHOLD: "20m"
  QUEUE_THRESHOLD: "10m"
  INVESTIGATION_THRESHOLD: "95"  # Trigger investigation at first sign of issues
```

## How It Works

### 1. Health Score Calculation
The system calculates an overall health score (0-100) based on:
- Number of failed pipelines
- Long-running pipeline count
- Queued pipeline count
- Repository policy violations
- Service connection issues

### 2. Conditional Investigation
When the health score falls below the `INVESTIGATION_THRESHOLD`, the system automatically triggers:

#### Pipeline Failure Investigation
- Analyzes failed runs from the last 24 hours
- Correlates failures with commit history
- Identifies patterns and recurring issues
- Provides commit author and change details

#### Repository Health Analysis
- Examines commit patterns and activity
- Checks branch protection policies
- Analyzes pull request status and age
- Identifies stale or problematic repositories

#### Performance Analysis
- Calculates pipeline duration trends
- Identifies performance bottlenecks
- Analyzes queue times and success rates
- Provides optimization recommendations

### 3. Intelligent Reporting
- **Healthy State**: Minimal reporting, fast execution
- **Issues Detected**: Comprehensive investigation with detailed insights
- **Health Summary**: Always provides overall project health metrics

## Benefits

### Operational Efficiency
1. **Resource Optimization**: Expensive analysis only runs when needed
2. **Fast Regular Checks**: Basic monitoring completes quickly
3. **Comprehensive Investigation**: Deep insights when problems occur
4. **Reduced Noise**: Focus on actionable issues

### Team Productivity
1. **Multi-Project Support**: Monitor related projects together
2. **Root Cause Analysis**: Understand why failures happen
3. **Performance Insights**: Identify optimization opportunities
4. **Proactive Monitoring**: Catch issues before they escalate

### Enterprise Scalability
1. **Flexible Scoping**: Single or multi-project configurations
2. **Conditional Execution**: Scales with your project health
3. **Consolidated Monitoring**: Fewer SLXs to manage
4. **Clear Attribution**: Issues clearly mapped to projects

## Task Execution Flow

```
1. Calculate Project Health Score (Always)
   ↓
2. Basic Health Checks (Always)
   - Agent Pools
   - Failed Pipelines  
   - Long Running Pipelines
   - Queued Pipelines
   - Repository Policies
   - Service Connections
   ↓
3. Health Score Evaluation
   ↓
4. Conditional Investigation (If health score < threshold)
   - Pipeline Failure Root Cause Analysis
   - Repository Health Analysis  
   - Performance Trend Analysis
   ↓
5. Generate Health Summary Report (Always)
```

## Output

### Always Generated
- Health score (0-100)
- Basic issue counts by category
- Project-level health summary
- Individual issues with severity levels

### Generated When Issues Detected
- Detailed failure analysis with commit correlation
- Repository activity patterns and policy compliance
- Performance trends and bottleneck identification
- Optimization recommendations

## Testing

The `.test` directory contains infrastructure test code using Terraform to set up a test environment that can be used to validate both basic monitoring and conditional investigation features.

### Prerequisites for Testing

1. An existing Azure subscription
2. An existing Azure DevOps organization
3. Permissions to create resources in Azure and Azure DevOps
4. Azure CLI installed and configured
5. Terraform installed (v1.0.0+)

### Test Environment Setup

The test environment creates multiple scenarios to validate the conditional investigation:
- Successful pipelines (healthy state)
- Failed pipelines (triggers investigation)
- Long-running pipelines (triggers performance analysis)
- Repository with various policy configurations

#### Step 1: Configure Terraform Variables

Create a `terraform.tfvars` file in the `.test/terraform` directory:

```hcl
azure_devops_org       = "your-org-name"
azure_devops_org_url   = "https://dev.azure.com/your-org-name"
resource_group         = "your-resource-group"
location               = "eastus"
tags                   = "your-tags"
```

#### Step 2: Initialize and Apply Terraform

```bash
cd .test/terraform
terraform init
terraform apply
```

#### Step 3: Test Different Health Scenarios

1. **Healthy State**: Run with all pipelines succeeding
2. **Failure State**: Trigger pipeline failures to test investigation
3. **Performance Issues**: Create long-running pipelines
4. **Policy Issues**: Modify repository policies

#### Step 4: Validate Conditional Behavior

Verify that:
- Basic checks always run quickly
- Investigation only triggers when issues are present
- Health score accurately reflects project state
- Detailed analysis provides actionable insights

### Cleaning Up

```bash
cd .test/terraform
terraform destroy
```

## Notes

- The codebundle uses the Azure CLI with the Azure DevOps extension
- Service principal authentication is used for Azure resources
- Basic health checks are optimized for speed and run every execution
- Deep investigation is resource-intensive and only runs when needed
- Health score calculation is customizable via the investigation threshold
- All investigation scripts are designed to handle API failures gracefully
- Multi-project support allows for flexible team-based monitoring strategies
