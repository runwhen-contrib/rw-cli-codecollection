# Current sub (assumed from CLI login)
data "azurerm_subscription" "current" {}

# Get tenant and user details of the current CLI session
data "azurerm_client_config" "current" {}

# Reference the existing parent DNS zone
data "azurerm_dns_zone" "parent_zone" {
  name                = var.parent_domain_name
  resource_group_name = var.parent_domain_resource_group
}

# Resource Group
resource "azurerm_resource_group" "test" {
  name     = var.resource_group
  location = var.location
  tags     = var.tags
}

# Virtual Network for DNS testing
resource "azurerm_virtual_network" "dns_test_vnet" {
  name                = "${var.resource_group}-vnet"
  address_space       = ["10.0.0.0/16"]
  location            = var.location
  resource_group_name = azurerm_resource_group.test.name
  depends_on          = [azurerm_resource_group.test]
}

# Subnet for DNS testing
resource "azurerm_subnet" "dns_test_subnet" {
  name                 = "dns-test-subnet"
  resource_group_name  = azurerm_resource_group.test.name
  virtual_network_name = azurerm_virtual_network.dns_test_vnet.name
  address_prefixes     = ["10.0.1.0/24"]
}

# Private DNS Zone for database testing
resource "azurerm_private_dns_zone" "database_zone" {
  name                = "privatelink.database.windows.net"
  resource_group_name = azurerm_resource_group.test.name
  depends_on          = [azurerm_resource_group.test]
}

# Private DNS Zone for app service testing
resource "azurerm_private_dns_zone" "appservice_zone" {
  name                = "privatelink.azurewebsites.net"
  resource_group_name = azurerm_resource_group.test.name
  depends_on          = [azurerm_resource_group.test]
}

# Private DNS Zone for blob storage testing
resource "azurerm_private_dns_zone" "blob_zone" {
  name                = "privatelink.blob.core.windows.net"
  resource_group_name = azurerm_resource_group.test.name
  depends_on          = [azurerm_resource_group.test]
}

# Public DNS Zone for testing (using a real subdomain)
resource "azurerm_dns_zone" "public_zone" {
  name                = var.public_domain
  resource_group_name = azurerm_resource_group.test.name
  depends_on          = [azurerm_resource_group.test]
}

# Link private DNS zones to VNet
resource "azurerm_private_dns_zone_virtual_network_link" "database_link" {
  name                  = "database-link"
  resource_group_name   = azurerm_resource_group.test.name
  private_dns_zone_name = azurerm_private_dns_zone.database_zone.name
  virtual_network_id    = azurerm_virtual_network.dns_test_vnet.id
  registration_enabled  = false
}

resource "azurerm_private_dns_zone_virtual_network_link" "appservice_link" {
  name                  = "appservice-link"
  resource_group_name   = azurerm_resource_group.test.name
  private_dns_zone_name = azurerm_private_dns_zone.appservice_zone.name
  virtual_network_id    = azurerm_virtual_network.dns_test_vnet.id
  registration_enabled  = false
}

resource "azurerm_private_dns_zone_virtual_network_link" "blob_link" {
  name                  = "blob-link"
  resource_group_name   = azurerm_resource_group.test.name
  private_dns_zone_name = azurerm_private_dns_zone.blob_zone.name
  virtual_network_id    = azurerm_virtual_network.dns_test_vnet.id
  registration_enabled  = false
}

# DNS Records for testing
resource "azurerm_private_dns_a_record" "database_record" {
  name                = "myapp"
  zone_name           = azurerm_private_dns_zone.database_zone.name
  resource_group_name = azurerm_resource_group.test.name
  ttl                 = 300
  records             = ["10.0.0.4"]
}

resource "azurerm_private_dns_a_record" "appservice_record" {
  name                = "myapi"
  zone_name           = azurerm_private_dns_zone.appservice_zone.name
  resource_group_name = azurerm_resource_group.test.name
  ttl                 = 300
  records             = ["10.0.0.5"]
}

resource "azurerm_private_dns_a_record" "blob_record" {
  name                = "myapp"
  zone_name           = azurerm_private_dns_zone.blob_zone.name
  resource_group_name = azurerm_resource_group.test.name
  ttl                 = 300
  records             = ["10.0.0.6"]
}

# Public DNS Records for testing
resource "azurerm_dns_a_record" "public_record" {
  name                = "www"
  zone_name           = azurerm_dns_zone.public_zone.name
  resource_group_name = azurerm_resource_group.test.name
  ttl                 = 300
  records             = ["1.2.3.4"]
}

# Root A record for the domain
resource "azurerm_dns_a_record" "root_record" {
  name                = "@"
  zone_name           = azurerm_dns_zone.public_zone.name
  resource_group_name = azurerm_resource_group.test.name
  ttl                 = 300
  records             = ["1.2.3.4"]
}

# API subdomain for testing
resource "azurerm_dns_a_record" "api_record" {
  name                = "api"
  zone_name           = azurerm_dns_zone.public_zone.name
  resource_group_name = azurerm_resource_group.test.name
  ttl                 = 300
  records             = ["5.6.7.8"]
}

# DNS Delegation: Create NS records in parent zone to delegate subdomain
resource "azurerm_dns_ns_record" "subdomain_delegation" {
  name                = replace(var.public_domain, ".${var.parent_domain_name}", "")
  zone_name           = data.azurerm_dns_zone.parent_zone.name
  resource_group_name = data.azurerm_dns_zone.parent_zone.resource_group_name
  ttl                 = 300
  records             = azurerm_dns_zone.public_zone.name_servers
}

# Assign "Reader" role to the service account for the resource group
resource "azurerm_role_assignment" "reader" {
  count                = var.sp_principal_id != "" ? 1 : 0
  scope                = azurerm_resource_group.test.id
  role_definition_name = "Reader"
  principal_id         = var.sp_principal_id
}

# Assign "DNS Zone Contributor" role for DNS management
resource "azurerm_role_assignment" "dns_contributor" {
  count                = var.sp_principal_id != "" ? 1 : 0
  scope                = azurerm_resource_group.test.id
  role_definition_name = "DNS Zone Contributor"
  principal_id         = var.sp_principal_id
}

# Output variables for testing the codebundle
output "export_commands" {
  description = "Copy and paste these export commands to set environment variables for DNS health testing"
  value       = <<-EOT
export AZ_RESOURCE_GROUP="${azurerm_resource_group.test.name}"
export RESOURCE_GROUPS="${azurerm_resource_group.test.name}"
export TEST_FQDNS="${azurerm_private_dns_a_record.database_record.name}.${azurerm_private_dns_zone.database_zone.name},${azurerm_private_dns_a_record.appservice_record.name}.${azurerm_private_dns_zone.appservice_zone.name},${azurerm_private_dns_a_record.blob_record.name}.${azurerm_private_dns_zone.blob_zone.name}"
export FORWARD_LOOKUP_ZONES="${azurerm_private_dns_zone.database_zone.name},${azurerm_private_dns_zone.appservice_zone.name},${azurerm_private_dns_zone.blob_zone.name}"
export PUBLIC_ZONES="${azurerm_dns_zone.public_zone.name}"
export DNS_RESOLVERS="168.63.129.16,8.8.8.8,1.1.1.1"
export DNS_SERVER_IPS="168.63.129.16,8.8.8.8,1.1.1.1"
export PUBLIC_DOMAINS="${azurerm_dns_zone.public_zone.name}"
export EXPRESS_ROUTE_DNS_ZONES="${azurerm_private_dns_zone.database_zone.name},${azurerm_private_dns_zone.appservice_zone.name},${azurerm_private_dns_zone.blob_zone.name}"
export VNET_ID="${azurerm_virtual_network.dns_test_vnet.id}"
export SUBNET_ID="${azurerm_subnet.dns_test_subnet.id}"
EOT
}

output "dns_zone_nameservers" {
  description = "Azure DNS nameservers for the public zone - configure these in your parent domain"
  value       = azurerm_dns_zone.public_zone.name_servers
}

output "public_domain" {
  description = "The public domain created for testing"
  value       = azurerm_dns_zone.public_zone.name
}

output "dns_delegation_status" {
  description = "DNS delegation status and information"
  value       = <<-EOT

=== DNS DELEGATION CONFIGURED ===

✅ DNS delegation has been automatically configured!

Parent Zone: ${data.azurerm_dns_zone.parent_zone.name} (${data.azurerm_dns_zone.parent_zone.resource_group_name})
Child Zone:  ${azurerm_dns_zone.public_zone.name} (${azurerm_resource_group.test.name})

NS Delegation Record: ${azurerm_dns_ns_record.subdomain_delegation.name}.${data.azurerm_dns_zone.parent_zone.name}
Nameservers: ${join(", ", azurerm_dns_zone.public_zone.name_servers)}

These domains should now resolve publicly:
   - ${azurerm_dns_zone.public_zone.name} -> 1.2.3.4
   - www.${azurerm_dns_zone.public_zone.name} -> 1.2.3.4  
   - api.${azurerm_dns_zone.public_zone.name} -> 5.6.7.8

The DNS health tests will work against real, resolvable domains!

EOT
}
