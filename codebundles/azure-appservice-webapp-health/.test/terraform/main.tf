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

# --------------------------------------
# Storage Account for the Function App
# --------------------------------------
resource "azurerm_storage_account" "function_storage" {
  name                     = "rwapsfuncstor"
  resource_group_name      = azurerm_resource_group.test.name
  location                 = azurerm_resource_group.test.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  account_kind             = "StorageV2"

  tags = var.tags
}

# --------------------------------------
# App Service Plan for the Function App
#   Using Consumption (Y1) on Linux
# --------------------------------------
resource "azurerm_service_plan" "function_plan" {
  name                = "${var.codebundle}-function-plan"
  location            = azurerm_resource_group.test.location
  resource_group_name = azurerm_resource_group.test.name
  os_type             = "Linux"
  sku_name            = "Y1" # Consumption plan
}

# --------------------------------------
# Linux Function App
# --------------------------------------
resource "azurerm_linux_function_app" "function_app" {
  name                       = "${var.codebundle}-func"
  location                   = azurerm_resource_group.test.location
  resource_group_name        = azurerm_resource_group.test.name
  service_plan_id            = azurerm_service_plan.function_plan.id
  storage_account_name       = azurerm_storage_account.function_storage.name
  storage_account_access_key = azurerm_storage_account.function_storage.primary_access_key

  # Optional site config - e.g., selecting a stack or custom settings
  site_config {
    application_stack {
      # Example for .NET 6
      dotnet_version = "8.0"
    }
  }

  # Optional managed identity
  identity {
    type = "SystemAssigned"
  }

  tags = var.tags
}

# --------------------------------------
# OUTPUT: Function App URL
# --------------------------------------
output "function_app_url" {
  value = azurerm_linux_function_app.function_app.default_hostname
}