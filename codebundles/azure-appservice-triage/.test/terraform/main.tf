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

resource "azurerm_service_plan" "f1" {
  name                = "${var.codebundle}-f1"
  location            = azurerm_resource_group.test.location
  resource_group_name = azurerm_resource_group.test.name
  os_type             = "Linux"
  sku_name            = "F1"
}

resource "azurerm_linux_web_app" "app-service-01" {
  name                = "${var.codebundle}-f1"
  location            = azurerm_resource_group.test.location
  resource_group_name = azurerm_resource_group.test.name
  service_plan_id     = azurerm_service_plan.f1.id

  site_config {
    always_on = false
  }
  tags = var.tags

}

resource "azurerm_service_plan" "b1" {
  name                = "${var.codebundle}-b1"
  location            = azurerm_resource_group.test.location
  resource_group_name = azurerm_resource_group.test.name
  os_type             = "Linux"
  sku_name            = "B1"
}

resource "azurerm_linux_web_app" "app-service-02" {
  name                = "${var.codebundle}-b1"
  location            = azurerm_resource_group.test.location
  resource_group_name = azurerm_resource_group.test.name
  service_plan_id     = azurerm_service_plan.b1.id

  site_config {
    always_on                         = false
    health_check_path                 = "/"
    health_check_eviction_time_in_min = 2
  }
  tags = var.tags

}

output "f1-app_service_url" {
  value = azurerm_linux_web_app.app-service-01.default_hostname
}

output "b1-app_service_url" {
  value = azurerm_linux_web_app.app-service-02.default_hostname
}

output "resource_group" {
  value = azurerm_resource_group.test.name
}