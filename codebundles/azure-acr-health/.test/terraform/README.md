# Terraform Infrastructure for ACR Health Testing

This Terraform configuration creates comprehensive Azure resources for testing the ACR health codebundle.

## Resources Created

### Container Registries
- **Premium ACR** (`${var.codebundle}acr${random_suffix}`)
  - Geo-replication to West US 2
  - Retention policy (7 days)
  - Trust policy enabled
  - Admin user enabled
  - Network rules configured
- **Basic ACR** (`${var.codebundle}basic${random_suffix}`)
  - No admin user (for auth testing)
  - Basic SKU limitations

### Monitoring & Logging
- **Log Analytics Workspace** with 30-day retention
- **Diagnostic Settings** for ACR events and metrics
- **Container Registry Events** logging
- **Login Events** logging

### Networking
- **Virtual Network** (10.0.0.0/16)
- **Private Endpoint Subnet** (10.0.1.0/24)
- **Private DNS Zone** (privatelink.azurecr.io)
- **DNS Zone VNet Link**
- **Private Endpoint** (commented out)

### Security & Access
- **RBAC Role Assignment** (AcrPull for service principal)
- **Network Security Rules**
- **IP Access Rules** (configurable)

### Testing Components
- **Test Webhook** pointing to httpbin.org
- **Sample Repository Data** (hello-world, nginx images)
- **Random Naming** for global uniqueness

## Variables

| Variable | Description | Default | Required |
|----------|-------------|---------|----------|
| `resource_group` | Resource group name | `"test-acr-rg"` | No |
| `location` | Azure region | `"East US"` | No |
| `codebundle` | Prefix for resource names | `"acrhealth"` | No |
| `sp_principal_id` | Service principal object ID | `""` | No |
| `subscription_id` | Azure subscription ID | `""` | No |
| `tenant_id` | Azure tenant ID | `""` | No |
| `tags` | Resource tags | See variables.tf | No |

## Outputs

| Output | Description |
|--------|-------------|
| `premium_acr_name` | Premium ACR registry name |
| `basic_acr_name` | Basic ACR registry name |
| `premium_acr_login_server` | Premium ACR login server URL |
| `basic_acr_login_server` | Basic ACR login server URL |
| `log_analytics_workspace_id` | Log Analytics workspace ID |
| `resource_group_name` | Resource group name |
| `premium_acr_admin_username` | Admin username (sensitive) |
| `premium_acr_admin_password` | Admin password (sensitive) |

## Usage

### Initialize and Deploy
```bash
# Initialize Terraform
terraform init

# Plan deployment
terraform plan -var="sp_principal_id=$(az ad sp show --id $AZ_CLIENT_ID --query id -o tsv)"

# Deploy
terraform apply -auto-approve
```

### Get Outputs
```bash
# Get ACR name for testing
export ACR_NAME=$(terraform output -raw premium_acr_name)

# Get credentials
export ACR_USERNAME=$(terraform output -raw premium_acr_admin_username)
export ACR_PASSWORD=$(terraform output -raw premium_acr_admin_password)

# Get workspace ID
export LOG_WORKSPACE_ID=$(terraform output -raw log_analytics_workspace_id)
```

### Test Connectivity
```bash
# Login to ACR
az acr login --name $ACR_NAME

# Test docker login
echo $ACR_PASSWORD | docker login $ACR_NAME.azurecr.io -u $ACR_USERNAME --password-stdin

# List repositories
az acr repository list --name $ACR_NAME
```

## Testing Scenarios

### Enable Private Endpoint Testing
Uncomment the private endpoint resources in `main.tf`:
```hcl
resource "azurerm_private_endpoint" "acr_pe" {
  # ... uncomment this block
}
```

Then update the ACR to disable public access:
```hcl
resource "azurerm_container_registry" "premium_acr" {
  # ...
  public_network_access_enabled = false
  # ...
}
```

### Modify Network Rules
Adjust IP rules for testing:
```hcl
network_rule_set {
  default_action = "Deny"  # Test restrictive access
  
  ip_rule {
    action   = "Allow"
    ip_range = "YOUR.IP.ADDRESS/32"  # Your specific IP
  }
}
```

### Test Storage Scenarios
Modify retention policy:
```hcl
retention_policy {
  days    = 1  # Very short retention for testing
  enabled = true
}
```

## Cleanup

```bash
# Destroy all resources
terraform destroy -auto-approve

# Clean up state files
rm -f terraform.tfstate*
rm -rf .terraform/
```

## Cost Optimization

To reduce costs during testing:

1. **Use shorter retention periods**:
   ```hcl
   retention_in_days = 7  # Instead of 30
   ```

2. **Disable geo-replication**:
   ```hcl
   # Comment out georeplications block
   ```

3. **Use Standard SKU** for testing (if Premium features not needed):
   ```hcl
   sku = "Standard"
   ```

## Security Considerations

### Network Security
- Default IP rule allows all traffic (`0.0.0.0/0`) - **FOR TESTING ONLY**
- Replace with specific IP ranges in production
- Use private endpoints for production scenarios

### Authentication
- Admin user is enabled for testing convenience
- Use Azure AD authentication in production
- Rotate credentials regularly

### RBAC
- Service principal gets `AcrPull` role
- Add additional roles as needed for testing:
  ```hcl
  resource "azurerm_role_assignment" "acr_push" {
    scope                = azurerm_container_registry.premium_acr.id
    role_definition_name = "AcrPush"
    principal_id         = var.sp_principal_id
  }
  ```

## Troubleshooting

### Common Issues

1. **ACR Name Conflicts**
   - ACR names must be globally unique
   - Random suffix helps avoid conflicts
   - Check if name is available: `az acr check-name --name myname`

2. **Permission Issues**
   - Ensure service principal has Contributor role on subscription
   - Check RBAC assignments: `az role assignment list --assignee $SP_ID`

3. **Network Connectivity**
   - Verify NSG rules don't block ACR traffic
   - Check if private endpoint DNS resolution works
   - Test from different network locations

4. **Image Import Failures**
   - Import may fail if source images are unavailable
   - Check image availability: `az acr import --dry-run`
   - Use alternative base images if needed

### Debug Commands

```bash
# Check ACR status
az acr show --name $ACR_NAME --query '{name:name,sku:sku.name,status:provisioningState}'

# Verify network rules
az acr network-rule list --name $ACR_NAME

# Test webhook
az acr webhook ping --name testwebhook --registry $ACR_NAME

# Check diagnostic settings
az monitor diagnostic-settings show --name acr-diagnostics --resource $ACR_RESOURCE_ID
```

## Advanced Configuration

### Multi-Region Testing
Add additional geo-replications:
```hcl
georeplications {
  location                = "West Europe"
  zone_redundancy_enabled = true
  tags                    = var.tags
}
```

### Custom Webhook Testing
Add webhook for specific scenarios:
```hcl
resource "azurerm_container_registry_webhook" "custom_webhook" {
  name                = "customhook"
  resource_group_name = azurerm_resource_group.acr_rg.name
  registry_name       = azurerm_container_registry.premium_acr.name
  location            = azurerm_resource_group.acr_rg.location

  service_uri = "https://your-endpoint.com/webhook"
  status      = "enabled"
  scope       = "*"
  actions     = ["push", "delete", "quarantine"]
}
```

### Log Analytics Queries
Test with custom queries:
```kql
ContainerRegistryRepositoryEvents
| where TimeGenerated > ago(24h)
| summarize count() by OperationName, ResultType
| order by count_ desc
```
