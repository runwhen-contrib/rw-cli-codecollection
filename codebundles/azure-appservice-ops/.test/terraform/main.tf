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

# Assign "Reader" role to the service account for the resource group
resource "azurerm_role_assignment" "website-contributor" {
  scope                = azurerm_resource_group.test.id
  role_definition_name = "Website Contributor"
  principal_id         = var.sp_principal_id
}

###############################################################################
# App Service Plans
###############################################################################
resource "azurerm_service_plan" "app1" {
  name                = "${var.resource_group}-app1-service-plan"
  location            = azurerm_resource_group.test.location
  resource_group_name = azurerm_resource_group.test.name
  os_type             = "Linux"
  sku_name            = "B1"
}

resource "azurerm_service_plan" "app2" {
  name                = "${var.resource_group}-app2-service-plan"
  location            = azurerm_resource_group.test.location
  resource_group_name = azurerm_resource_group.test.name
  os_type             = "Linux"
  sku_name            = "B1"
}

###############################################################################
# App Services
###############################################################################
resource "azurerm_linux_web_app" "app1" {
  name                = "${var.resource_group}-app1-web"
  location            = azurerm_resource_group.test.location
  resource_group_name = azurerm_resource_group.test.name
  service_plan_id     = azurerm_service_plan.app1.id

  app_settings = {
    "GAME" = "oregon"
  }

  site_config {
    always_on                         = true
    health_check_path                 = "/"
    health_check_eviction_time_in_min = 2
    application_stack {
      docker_image_name   = "stewartshea/js-dos-container:latest"
      docker_registry_url = "https://ghcr.io"
    }
  }
  tags = var.tags
}

resource "azurerm_linux_web_app" "app2" {
  name                = "${var.resource_group}-app2-web"
  location            = azurerm_resource_group.test.location
  resource_group_name = azurerm_resource_group.test.name
  service_plan_id     = azurerm_service_plan.app2.id

  app_settings = {
    "GAME" = "scorched_earth"
  }

  site_config {
    always_on                         = true
    health_check_path                 = "/"
    health_check_eviction_time_in_min = 2
    application_stack {
      docker_image_name   = "stewartshea/js-dos-container:broken"
      docker_registry_url = "https://ghcr.io"
    }
  }
  tags = var.tags
}

output "f1-app_service_url" {
  value = azurerm_linux_web_app.app1.default_hostname
}

output "b1-app_service_url" {
  value = azurerm_linux_web_app.app2.default_hostname
}

output "resource_group" {
  value = azurerm_resource_group.test.name
}