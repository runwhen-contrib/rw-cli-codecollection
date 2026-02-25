provider "azurerm" {
  features {}
}

# Random string for unique ACR name
resource "random_string" "acr_suffix" {
  length  = 8
  special = false
  upper   = false
  numeric = true
}

# Data sources
data "azurerm_subscription" "current" {}
data "azurerm_client_config" "current" {}

# Resource group for ACR resources
resource "azurerm_resource_group" "acr_rg" {
  name     = var.resource_group
  location = var.location
  tags     = var.tags
}

# Log Analytics workspace for ACR monitoring (cost-optimized)
resource "azurerm_log_analytics_workspace" "acr_logs" {
  name                = "${var.codebundle}-acr-logs-${random_string.acr_suffix.result}"
  location            = azurerm_resource_group.acr_rg.location
  resource_group_name = azurerm_resource_group.acr_rg.name
  sku                 = "PerGB2018"
  retention_in_days   = var.log_retention_days # Cost-conscious: 30 days minimum (Azure requirement)
  tags                = var.tags
}

# Primary ACR for testing (cost-optimized: Standard by default)
resource "azurerm_container_registry" "primary_acr" {
  name                = "${var.codebundle}acr${random_string.acr_suffix.result}"
  resource_group_name = azurerm_resource_group.acr_rg.name
  location            = azurerm_resource_group.acr_rg.location
  sku                 = var.primary_acr_sku # Cost-conscious: Standard by default
  admin_enabled       = true

  # Conditional geo-replication (only for Premium, only if enabled)
  dynamic "georeplications" {
    for_each = var.primary_acr_sku == "Premium" && var.enable_geo_replication ? [1] : []
    content {
      location                = "West US 2"
      zone_redundancy_enabled = false
      tags                    = var.tags
    }
  }

  # Network access configuration for testing
  public_network_access_enabled = true

  # Network rules only available for Premium SKU
  dynamic "network_rule_set" {
    for_each = var.primary_acr_sku == "Premium" ? [1] : []
    content {
      default_action = "Allow"

      # Example IP rule (replace with your IP for testing)
      ip_rule {
        action   = "Allow"
        ip_range = "0.0.0.0/0" # WARNING: This is overly permissive, use specific IPs in production
      }
    }
  }

  # Note: retention_policy and trust_policy are managed via separate resources in newer AzureRM provider versions

  tags = var.tags
}

# Note: Retention policy and trust policy are managed via Azure CLI in the test data population script
# These features are not yet supported as separate Terraform resources in the AzureRM provider

# Basic ACR for comparison testing
resource "azurerm_container_registry" "basic_acr" {
  name                = "${var.codebundle}basic${random_string.acr_suffix.result}"
  resource_group_name = azurerm_resource_group.acr_rg.name
  location            = azurerm_resource_group.acr_rg.location
  sku                 = "Basic"
  admin_enabled       = false # Test without admin user
  tags                = var.tags
}

# Virtual Network for private endpoint testing
resource "azurerm_virtual_network" "acr_vnet" {
  name                = "${var.codebundle}-acr-vnet"
  location            = azurerm_resource_group.acr_rg.location
  resource_group_name = azurerm_resource_group.acr_rg.name
  address_space       = ["10.0.0.0/16"]
  tags                = var.tags
}

# Subnet for private endpoint
resource "azurerm_subnet" "private_endpoint_subnet" {
  name                 = "private-endpoint-subnet"
  resource_group_name  = azurerm_resource_group.acr_rg.name
  virtual_network_name = azurerm_virtual_network.acr_vnet.name
  address_prefixes     = ["10.0.1.0/24"]

  private_endpoint_network_policies = "Disabled"
}

# Private DNS Zone for ACR
resource "azurerm_private_dns_zone" "acr_dns" {
  name                = "privatelink.azurecr.io"
  resource_group_name = azurerm_resource_group.acr_rg.name
  tags                = var.tags
}

# Link private DNS zone to VNet
resource "azurerm_private_dns_zone_virtual_network_link" "acr_dns_link" {
  name                  = "acr-dns-link"
  resource_group_name   = azurerm_resource_group.acr_rg.name
  private_dns_zone_name = azurerm_private_dns_zone.acr_dns.name
  virtual_network_id    = azurerm_virtual_network.acr_vnet.id
  registration_enabled  = false
  tags                  = var.tags
}

# Optional private endpoint (disabled by default for cost savings)
resource "azurerm_private_endpoint" "acr_pe" {
  count               = var.enable_private_endpoint ? 1 : 0
  name                = "${var.codebundle}-acr-pe"
  location            = azurerm_resource_group.acr_rg.location
  resource_group_name = azurerm_resource_group.acr_rg.name
  subnet_id           = azurerm_subnet.private_endpoint_subnet.id
  tags                = var.tags

  private_service_connection {
    name                           = "acr-private-connection"
    private_connection_resource_id = azurerm_container_registry.primary_acr.id
    subresource_names              = ["registry"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "acr-dns-zone-group"
    private_dns_zone_ids = [azurerm_private_dns_zone.acr_dns.id]
  }
}

# Diagnostic settings for ACR monitoring
resource "azurerm_monitor_diagnostic_setting" "acr_diagnostics" {
  name                       = "acr-diagnostics"
  target_resource_id         = azurerm_container_registry.primary_acr.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.acr_logs.id

  enabled_log {
    category = "ContainerRegistryRepositoryEvents"
  }

  enabled_log {
    category = "ContainerRegistryLoginEvents"
  }

  enabled_metric {
    category = "AllMetrics"
  }
}

# Role assignments for testing RBAC
resource "azurerm_role_assignment" "acr_reader" {
  count                = var.sp_principal_id != "" ? 1 : 0
  scope                = azurerm_container_registry.primary_acr.id
  role_definition_name = "AcrPull"
  principal_id         = var.sp_principal_id
}

# Webhook for testing (only for Standard/Premium SKUs)
resource "azurerm_container_registry_webhook" "test_webhook" {
  count               = contains(["Standard", "Premium"], var.primary_acr_sku) ? 1 : 0
  name                = "testwebhook"
  resource_group_name = azurerm_resource_group.acr_rg.name
  registry_name       = azurerm_container_registry.primary_acr.name
  location            = azurerm_resource_group.acr_rg.location

  service_uri = "https://httpbin.org/post" # Test endpoint
  status      = "enabled"
  scope       = "test-repo:*"
  actions     = ["push", "delete"]

  custom_headers = {
    "Content-Type" = "application/json"
  }

  tags = var.tags
}

# Outputs
output "primary_acr_name" {
  description = "Primary ACR registry name"
  value       = azurerm_container_registry.primary_acr.name
}

output "basic_acr_name" {
  description = "Basic ACR registry name"
  value       = azurerm_container_registry.basic_acr.name
}

output "primary_acr_login_server" {
  description = "Primary ACR login server URL"
  value       = azurerm_container_registry.primary_acr.login_server
}

output "basic_acr_login_server" {
  description = "Basic ACR login server URL"
  value       = azurerm_container_registry.basic_acr.login_server
}

output "primary_acr_sku" {
  description = "Primary ACR SKU tier"
  value       = azurerm_container_registry.primary_acr.sku
}

output "log_analytics_workspace_id" {
  description = "Log Analytics workspace ID"
  value       = azurerm_log_analytics_workspace.acr_logs.workspace_id
}

output "resource_group_name" {
  description = "Resource group name"
  value       = azurerm_resource_group.acr_rg.name
}

output "primary_acr_admin_username" {
  description = "Primary ACR admin username"
  value       = azurerm_container_registry.primary_acr.admin_username
  sensitive   = true
}

output "primary_acr_admin_password" {
  description = "Primary ACR admin password"
  value       = azurerm_container_registry.primary_acr.admin_password
  sensitive   = true
}

output "estimated_monthly_cost_usd" {
  description = "Estimated monthly cost in USD (approximate)"
  value = format("$%.2f",
    # Primary ACR cost
    (var.primary_acr_sku == "Basic" ? 5.0 :
    var.primary_acr_sku == "Standard" ? 20.0 : 100.0) +
    # Basic ACR cost  
    5.0 +
    # Log Analytics (assuming 1GB/month)
    2.30 +
    # VNet cost
    3.65 +
    # Geo-replication cost (if enabled)
    (var.primary_acr_sku == "Premium" && var.enable_geo_replication ? 100.0 : 0.0) +
    # Private endpoint cost (if enabled)
    (var.enable_private_endpoint ? 7.30 : 0.0)
  )
}

# Test data - create some repositories for testing (cost-conscious: smaller images)
resource "null_resource" "populate_acr" {
  depends_on = [azurerm_container_registry.primary_acr]

  provisioner "local-exec" {
    command = <<-EOT
      # Login to ACR
      az acr login --name ${azurerm_container_registry.primary_acr.name} --username ${azurerm_container_registry.primary_acr.admin_username} --password ${azurerm_container_registry.primary_acr.admin_password}
      
      # Import small test images to minimize storage costs
      az acr import --name ${azurerm_container_registry.primary_acr.name} --source mcr.microsoft.com/hello-world:latest --image test-repo/hello-world:v1.0 || true
      az acr import --name ${azurerm_container_registry.primary_acr.name} --source mcr.microsoft.com/oss/busybox/busybox:1.35 --image test-repo/busybox:latest || true
      
      # Configure retention policy for Standard/Premium ACRs
      if [[ "${var.primary_acr_sku}" != "Basic" ]]; then
        az acr config retention update --name ${azurerm_container_registry.primary_acr.name} --type UntaggedManifests --days 7 --status enabled || true
      fi
      
      # Configure trust policy for Premium ACRs  
      if [[ "${var.primary_acr_sku}" == "Premium" ]]; then
        az acr config content-trust update --name ${azurerm_container_registry.primary_acr.name} --status enabled || true
      fi
    EOT
  }
}
