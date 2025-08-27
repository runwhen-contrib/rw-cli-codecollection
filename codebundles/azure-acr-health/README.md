# Azure Container Registry (ACR) Health Bundle

This bundle provides comprehensive health checks for Azure Container Registries (ACR), including network configuration analysis, resource health monitoring, authentication testing, storage utilization analysis, pull/push metrics, and security assessments. It uses Robot Framework tasks and Bash scripts to collect, parse, and score ACR health with detailed troubleshooting guidance.

## Included Health Checks

- **Azure Resource Health**: Integrates with Azure Resource Health API to detect platform-level issues
- **Network Configuration**: Analyzes network access rules, private endpoints, firewall settings, and connectivity
- **DNS & TLS Reachability**: Verifies DNS resolution and HTTPS/TLS connectivity to ACR endpoint
- **Authentication & Authorization**: Tests login capabilities and analyzes authentication methods
- **SKU & Usage Analysis**: Comprehensive analysis of ACR SKU, usage limits, and recommendations
- **Storage Utilization**: Detailed storage usage analysis with cleanup recommendations and retention policy checks
- **Pull/Push Success Metrics**: Analyzes operation success rates using Azure Monitor and Log Analytics
- **Repository Events**: Queries Log Analytics for failed operations and error patterns
- **Geo-replication Health**: Checks multi-region replication status (Premium SKU)
- **Webhook Configuration**: Validates webhook endpoints and connectivity

## Main Tasks

### Runbook Tasks (Issue Detection & Remediation)
- `Check for Resource Health Issues Affecting ACR`
- `Check Network Configuration for ACR`
- `Check DNS & TLS Reachability for Registry`
- `Check ACR Login & Authentication`
- `Check ACR SKU and Usage Metrics`
- `Check ACR Storage Utilization`
- `Analyze ACR Pull/Push Success Ratio`
- `Check ACR Repository Event Failures`

### SLI Tasks (Health Scoring)
- `Check ACR Reachability`
- `Check ACR Usage SKU Metric`
- `Check ACR Pull/Push Success Ratio`
- `Check ACR Storage Utilization`
- `Check ACR Network Configuration`
- `Check ACR Resource Health`
- `Generate Comprehensive ACR Health Score`

## How It Works

1. **Comprehensive Bash scripts** collect detailed data from Azure Container Registry, Azure Resource Health API, Azure Monitor, and Log Analytics
2. **Robot Framework tasks** execute scripts, parse structured JSON output, and generate actionable issues with severity classification
3. **Advanced error handling** provides detailed troubleshooting context including network configuration, IP whitelists, and authentication methods
4. **Portal URL generation** for easy navigation to relevant Azure portal sections
5. **SLI tasks** aggregate results into a comprehensive health score for monitoring

## Configuration

### Required Environment Variables

- `AZURE_SUBSCRIPTION_ID`: The Azure subscription ID
- `AZ_RESOURCE_GROUP`: The resource group containing the ACR
- `ACR_NAME`: Azure Container Registry name
- `ACR_PASSWORD`: ACR admin password or service principal credential (secret)

### Optional Configuration Variables

- `AZURE_SUBSCRIPTION_NAME`: Friendly name for the subscription (default: "subscription-01")
- `LOG_WORKSPACE_ID`: Log Analytics Workspace ID for detailed event analysis
- `USAGE_THRESHOLD`: Storage usage threshold percentage (default: 80)
- `CRITICAL_THRESHOLD`: Critical storage threshold percentage (default: 95)
- `TIME_PERIOD_HOURS`: Time period for pull/push analysis in hours (default: 24)
- `PULL_SUCCESS_THRESHOLD`: Pull success rate threshold percentage (default: 95)
- `PUSH_SUCCESS_THRESHOLD`: Push success rate threshold percentage (default: 98)

### Example Usage

```bash
# Set required variables
export AZURE_SUBSCRIPTION_ID="your-subscription-id"
export AZ_RESOURCE_GROUP="your-resource-group"
export ACR_NAME="your-acr-name"
export LOG_WORKSPACE_ID="your-log-analytics-workspace-id"

# Run comprehensive health check
robot runbook.robot

# Run SLI scoring only
robot sli.robot
```

## Directory Structure

### Core Files
- `runbook.robot` - Main runbook with comprehensive health checks and issue generation
- `sli.robot` - Service Level Indicator scoring for monitoring integration

### Health Check Scripts
- `acr_resource_health.sh` - Azure Resource Health API integration
- `acr_network_config.sh` - Network configuration and connectivity analysis
- `acr_reachability.sh` - DNS and TLS connectivity testing
- `acr_authentication.sh` - Authentication and login testing
- `acr_usage_sku.sh` - SKU analysis and usage recommendations
- `acr_storage_utilization.sh` - Comprehensive storage analysis with cleanup guidance
- `acr_pull_push_ratio.sh` - Pull/push success rate analysis with Azure Monitor integration
- `acr_events.sh` - Log Analytics event analysis

### Test Infrastructure
- `.test/terraform/` - Comprehensive Terraform infrastructure for testing
  - Creates Premium and Basic ACR instances
  - Log Analytics workspace with diagnostic settings
  - Virtual network and private endpoint configuration
  - RBAC assignments and webhook testing
  - Sample repository data for testing

## Features

### Advanced Error Handling
- **Severity Classification**: Issues categorized from 1 (Critical) to 4 (Informational)
- **Contextual Information**: Detailed error context with specific remediation steps
- **Portal Integration**: Direct links to relevant Azure portal sections
- **Network Troubleshooting**: IP configuration analysis and connectivity testing

### Comprehensive Coverage
- **Multi-SKU Support**: Optimized checks for Basic, Standard, and Premium SKUs
- **Private Endpoint Support**: Network analysis for private endpoint configurations
- **Geo-replication Monitoring**: Health checks for multi-region deployments
- **Security Analysis**: Authentication method recommendations and RBAC validation

### Monitoring Integration
- **Azure Monitor**: Pull/push metrics analysis with configurable thresholds
- **Log Analytics**: Event correlation and failure pattern detection
- **Resource Health**: Platform-level issue detection and historical analysis
- **Webhook Validation**: Endpoint reachability and configuration verification
- `.test/` - Example and test cases. 