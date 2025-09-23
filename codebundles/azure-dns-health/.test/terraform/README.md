# DNS Health Test Infrastructure

This Terraform configuration creates the necessary Azure infrastructure for testing the DNS health codebundle.

## Resources Created

### Resource Group
- `azure-dns-health` - Main resource group for DNS testing

### Virtual Network
- `azure-dns-health-vnet` - Virtual network for DNS testing
- Subnet: `10.0.1.0/24`

### Private DNS Zones
- `privatelink.database.windows.net` - For database private endpoints
- `privatelink.azurewebsites.net` - For app service private endpoints  
- `privatelink.blob.core.windows.net` - For blob storage private endpoints

### Public DNS Zone
- `dns-health-test.com` - Public DNS zone for testing

### DNS Records
- Private DNS A records for testing resolution
- Public DNS A records for external testing

### Role Assignments
- Reader role for resource group access
- DNS Zone Contributor role for DNS management

## Usage

1. Set environment variables:
```bash
export ARM_SUBSCRIPTION_ID="your-subscription-id"
export AZ_TENANT_ID="your-tenant-id"
export AZ_CLIENT_ID="your-client-id"
export AZ_CLIENT_SECRET="your-client-secret"
```

2. Initialize and apply:
```bash
terraform init
terraform plan
terraform apply
```

3. Test DNS health using exported variables:
```bash
# Get the export commands from Terraform and copy/paste them
terraform output export_commands

# Copy and paste the output, then run the DNS health tests
ro sli.robot
ro runbook.robot
```

## Cleanup

To destroy the infrastructure:
```bash
terraform destroy
```
