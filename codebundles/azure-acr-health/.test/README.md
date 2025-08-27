# Azure ACR Health Test Infrastructure

This directory contains comprehensive test infrastructure for the Azure Container Registry (ACR) health codebundle. It creates realistic Azure resources to test all health check scenarios and edge cases.

## Overview

The test infrastructure deploys cost-conscious Azure resources:
- **Primary ACR** (Standard SKU by default, configurable to Basic/Premium)
- **Basic ACR** for comparison testing without admin user
- **Log Analytics Workspace** with minimal retention (30 days, Azure minimum) for cost savings
- **Virtual Network** with optional private endpoint (disabled by default)
- **RBAC assignments** for security testing
- **Optional webhooks** (only for Standard/Premium SKUs)
- **Minimal test repository data** (small images to reduce storage costs)

## 💰 Cost-Conscious Design

**Default Monthly Cost: ~$31** (vs $150+ with Premium)
- Standard ACR: ~$20/month (vs Premium $100+/month)
- Basic ACR: ~$5/month
- Log Analytics: ~$2/month (30-day retention, Azure minimum)
- VNet: ~$4/month
- **Optional Premium features** can be enabled for comprehensive testing

## Prerequisites

### Required Tools
- [Azure CLI](https://docs.microsoft.com/en-us/cli/azure/install-azure-cli) (version 2.37+)
- [Terraform](https://www.terraform.io/downloads) (version 1.0+)
- [Task](https://taskfile.dev/) (for automation)
- [jq](https://stedolan.github.io/jq/) (for JSON processing)

### Azure Authentication
Ensure you're authenticated to Azure:
```bash
az login
az account set --subscription "your-subscription-id"
```

### Environment Setup
Create a `terraform/tf.secret` file with your Azure credentials:
```bash
# Create the secrets file
cat > terraform/tf.secret << EOF
export ARM_SUBSCRIPTION_ID="your-subscription-id"
export ARM_TENANT_ID="your-tenant-id"
export ARM_CLIENT_ID="your-service-principal-client-id"
export ARM_CLIENT_SECRET="your-service-principal-secret"
export AZ_TENANT_ID="your-tenant-id"
export AZ_CLIENT_ID="your-service-principal-client-id"
export AZ_CLIENT_SECRET="your-service-principal-secret"
EOF

# Make it executable
chmod +x terraform/tf.secret
```

## Quick Start

### 1. Choose Your Configuration
```bash
# Navigate to test directory
cd .test

# See cost estimates for different configurations
task cost-calculator

# Deploy cost-conscious infrastructure (recommended for CI/CD)
task build-infra-basic  # ~$16/month

# Or deploy balanced infrastructure (recommended for comprehensive testing)
task build-infra-standard  # ~$31/month

# Or deploy full-featured infrastructure (all ACR features)
task build-infra-premium  # ~$218/month
```

### 2. Verify Deployment
```bash
# Check infrastructure status
task check-terraform-infra
```

### 3. Run Health Checks
```bash
# Set environment variables from Terraform outputs
export ACR_NAME=$(cd terraform && terraform output -raw primary_acr_name)
export AZ_RESOURCE_GROUP=$(cd terraform && terraform output -raw resource_group_name)
export AZURE_SUBSCRIPTION_ID="your-subscription-id"
export LOG_WORKSPACE_ID=$(cd terraform && terraform output -raw log_analytics_workspace_id)
export ACR_PASSWORD=$(cd terraform && terraform output -raw primary_acr_admin_password)

# Check estimated costs
cd terraform && terraform output estimated_monthly_cost_usd

# Run comprehensive health check
cd ..
robot runbook.robot

# Run SLI scoring
robot sli.robot
```

### 4. Clean Up
```bash
cd .test
task clean
```

## Available Tasks

Use `task --list` to see all available tasks:

### 💰 Cost Management
- `task cost-calculator` - Show estimated costs for different configurations
- `task build-infra-basic` - Deploy ultra cost-conscious infrastructure (~$16/month)
- `task build-infra-standard` - Deploy balanced infrastructure (~$31/month)
- `task build-infra-premium` - Deploy full-featured infrastructure (~$218/month)

### Infrastructure Management
- `task build-infra` - Deploy default Terraform infrastructure (Standard ACR)
- `task check-terraform-infra` - Check current infrastructure status
- `task cleanup-terraform-infra` - Destroy infrastructure
- `task check-and-cleanup-terraform` - Conditional cleanup

### Testing & Validation
- `task validate-generation-rules` - Validate YAML generation rules
- `task run-rwl-discovery` - Run RunWhen Local discovery
- `task generate-rwl-config` - Generate workspace configuration

### Platform Integration
- `task upload-slxs` - Upload SLX files to RunWhen Platform
- `task delete-slxs` - Delete SLX files from platform

## Test Scenarios

### 1. Multi-SKU Testing
The infrastructure creates both Premium and Basic ACRs to test:
- **Premium features**: Geo-replication, retention policies, trust policies
- **Basic limitations**: No webhooks, limited storage, no geo-replication
- **SKU-specific recommendations** and health checks

### 2. Network Configuration Testing
- **Public access** with configurable IP rules
- **Private endpoint** infrastructure (commented out, can be enabled)
- **DNS resolution** testing with private DNS zones
- **Webhook connectivity** validation

### 3. Monitoring & Logging
- **Log Analytics workspace** with diagnostic settings
- **Container registry events** logging
- **Metrics collection** for pull/push operations
- **Historical data** for trend analysis

### 4. Security & RBAC
- **Service principal** role assignments
- **Admin user** vs **Azure AD authentication** testing
- **RBAC permissions** validation
- **Network security** rule testing

### 5. Storage & Repository Testing
- **Sample repositories** with test images
- **Storage utilization** scenarios
- **Retention policy** validation
- **Repository cleanup** testing

## Test Data

The infrastructure automatically populates test data:
```bash
# Sample repositories created:
# - test-repo/hello-world:v1.0
# - test-repo/nginx:latest
```

## Terraform Outputs

Key outputs available for testing:
```bash
# Get ACR names
terraform output premium_acr_name
terraform output basic_acr_name

# Get connection details
terraform output premium_acr_login_server
terraform output log_analytics_workspace_id

# Get credentials (sensitive)
terraform output premium_acr_admin_username
terraform output premium_acr_admin_password
```

## Environment Variables for Testing

### Required Variables
```bash
export AZURE_SUBSCRIPTION_ID="$(terraform output -raw subscription_id)"
export AZ_RESOURCE_GROUP="$(terraform output -raw resource_group_name)"
export ACR_NAME="$(terraform output -raw premium_acr_name)"
export ACR_PASSWORD="$(terraform output -raw premium_acr_admin_password)"
```

### Optional Variables
```bash
export LOG_WORKSPACE_ID="$(terraform output -raw log_analytics_workspace_id)"
export AZURE_SUBSCRIPTION_NAME="Test Subscription"
export USAGE_THRESHOLD="80"
export CRITICAL_THRESHOLD="95"
export TIME_PERIOD_HOURS="24"
export PULL_SUCCESS_THRESHOLD="95"
export PUSH_SUCCESS_THRESHOLD="98"
```

## Testing Different Scenarios

### Test Network Issues
```bash
# Test with overly permissive IP rules (should generate warnings)
# The infrastructure includes 0.0.0.0/0 rule for testing

# Enable private endpoint testing
# Uncomment private endpoint resources in main.tf
```

### Test Storage Issues
```bash
# Push large images to test storage thresholds
az acr login --name $ACR_NAME
docker pull nginx:latest
docker tag nginx:latest $ACR_NAME.azurecr.io/test/large-image:v1
docker push $ACR_NAME.azurecr.io/test/large-image:v1
```

### Test Authentication Issues
```bash
# Test with Basic ACR (no admin user)
export ACR_NAME="$(terraform output -raw basic_acr_name)"
# This should generate authentication-related issues
```

### Test Resource Health Issues
```bash
# Resource health issues are simulated by Azure platform
# Monitor the resource health status in Azure portal
```

## Troubleshooting

### Common Issues

#### 1. Terraform Deployment Fails
```bash
# Check Azure authentication
az account show

# Verify service principal permissions
az role assignment list --assignee $ARM_CLIENT_ID

# Check resource naming conflicts
# ACR names must be globally unique
```

#### 2. ACR Login Issues
```bash
# Verify admin user is enabled
az acr show --name $ACR_NAME --query adminUserEnabled

# Test manual login
az acr login --name $ACR_NAME
```

#### 3. Log Analytics Issues
```bash
# Verify diagnostic settings
az monitor diagnostic-settings list --resource $ACR_RESOURCE_ID

# Check workspace permissions
az role assignment list --scope $LOG_ANALYTICS_WORKSPACE_ID
```

### Debug Commands
```bash
# Check all resources
terraform state list

# Verify ACR configuration
az acr show --name $ACR_NAME

# Test connectivity
curl -I https://$ACR_NAME.azurecr.io/v2/

# Check logs
az monitor log-analytics query \
  --workspace $LOG_WORKSPACE_ID \
  --analytics-query "ContainerRegistryRepositoryEvents | limit 10"
```

## Cost Management

### Default Configuration (Cost-Optimized)
**Estimated Monthly Cost: ~$31**
- Standard ACR: ~$20/month
- Basic ACR: ~$5/month  
- Log Analytics: ~$2/month (30-day retention)
- Virtual Network: ~$4/month
- Private Endpoint: $0 (disabled by default)

### Premium Configuration (Full Features)
**Estimated Monthly Cost: ~$150+**
```bash
# Deploy with Premium features
terraform apply -var="primary_acr_sku=Premium" -var="enable_geo_replication=true" -var="enable_private_endpoint=true"
```

### Ultra Cost-Conscious (Basic Only)
**Estimated Monthly Cost: ~$16**
```bash
# Deploy minimal configuration
terraform apply -var="primary_acr_sku=Basic" -var="log_retention_days=30"
```

### Cost Monitoring
```bash
# Check estimated costs before deployment
terraform plan -var="primary_acr_sku=Premium"
terraform output estimated_monthly_cost_usd

# Monitor actual costs in Azure portal
az consumption usage list --start-date $(date -d '1 month ago' +%Y-%m-%d) --end-date $(date +%Y-%m-%d)
```

**⚠️ Cost Alert**: Always clean up resources after testing to avoid ongoing charges!

## Contributing

When adding new test scenarios:
1. Update `main.tf` with new resources
2. Add corresponding variables to `variables.tf`
3. Update this README with new test procedures
4. Add cleanup procedures for new resources

## Security Notes

- The test infrastructure uses **overly permissive** network rules for testing
- **Admin users are enabled** for testing purposes
- **Do not use** test configurations in production
- **Clean up** resources after testing to avoid security exposure
- **Rotate credentials** regularly in the `tf.secret` file
