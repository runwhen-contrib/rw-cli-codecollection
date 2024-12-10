# Current sub (assumed from CLI login)
data "azurerm_subscription" "current" {}

# Get tenant and user details of the current CLI session
data "azurerm_client_config" "current" {}

# Resource Group
resource "azurerm_resource_group" "test" {
  name     = var.resource_group
  location = var.location
  tags     = var.tags

}

# Assign "Reader" role to the service account for the resource group
resource "azurerm_role_assignment" "reader" {
  scope                = azurerm_resource_group.test.id
  role_definition_name = "Reader"
  principal_id         = var.sp_principal_id
}

resource "azurerm_service_plan" "app-service-plan-01" {
  name                = "${var.codebundle}-01"
  location            = azurerm_resource_group.test.location
  resource_group_name = azurerm_resource_group.test.name
  os_type             = "Linux"
  sku_name            = "F1"
}

resource "azurerm_linux_web_app" "app-service-01" {
  name                = "${var.codebundle}-01"
  location            = azurerm_resource_group.test.location
  resource_group_name = azurerm_resource_group.test.name
  service_plan_id     = azurerm_service_plan.app-service-plan-01.id

  site_config {
    always_on = false
  }

}

output "app_service_url" {
  value = azurerm_linux_web_app.app-service-01.default_hostname
}

output "resource_group" {
  value = azurerm_resource_group.test.name
}