provider "azurerm" {
  features {}
}

resource "azurerm_resource_group" "acr_rg" {
  name     = var.resource_group
  location = "East US"
}

resource "azurerm_container_registry" "demo_acr" {
  name                = "uniqueacrname12345" # must be globally unique, change as needed
  resource_group_name = azurerm_resource_group.acr_rg.name
  location            = azurerm_resource_group.acr_rg.location
  sku                 = "Basic"
  admin_enabled       = true
}

output "acr_name" {
  value = azurerm_container_registry.demo_acr.name
}

# output "acr_admin_username" {
#   value     = azurerm_container_registry.demo_acr.admin_username
#   sensitive = true
# }

# output "acr_admin_password" {
#   value     = azurerm_container_registry.demo_acr.admin_password
#   sensitive = true
# }

output "acr_login_server" {
  value = azurerm_container_registry.demo_acr.login_server
}
