###############################################################################
# Random string resource for unique Storage Account suffix
###############################################################################
resource "random_string" "storage_suffix" {
  length  = 5
  special = false
  upper   = false
  numeric = true
  # e.g. produces something like "12345"
  # All-lowercase alpha is also okay, as storage account names must be lowercase.
}

########################################
# DATA SOURCES
########################################

# Current subscription & client config
data "azurerm_subscription" "current" {}
data "azurerm_client_config" "current" {}

########################################
# RESOURCE GROUPS
########################################

# Resource group for the simple Web App
resource "azurerm_resource_group" "web_rg" {
  name     = var.resource_group
  location = var.location
  tags     = var.tags
}

# Resource group for the Function Apps
resource "azurerm_resource_group" "function_rg" {
  name     = "${var.codebundle}-functions-rg"
  location = var.location
  tags     = var.tags
}

########################################
# ROLE ASSIGNMENTS (optional)
########################################

# Example: "Reader" + "Website Contributor" for Web App resource group
# Temporarily commented out due to principal ID issues
# resource "azurerm_role_assignment" "reader_webapp" {
#   scope                = azurerm_resource_group.web_rg.id
#   role_definition_name = "Reader"
#   principal_id         = var.sp_principal_id
# }

# resource "azurerm_role_assignment" "website_contributor_webapp" {
#   scope                = azurerm_resource_group.web_rg.id
#   role_definition_name = "Website Contributor"
#   principal_id         = var.sp_principal_id
# }

# Example: "Reader" role for Function Apps resource group
# Temporarily commented out due to principal ID issues
# resource "azurerm_role_assignment" "reader_function_rg" {
#   scope                = azurerm_resource_group.function_rg.id
#   role_definition_name = "Reader"
#   principal_id         = var.sp_principal_id
# }

########################################
# SIMPLE WEB APP
########################################

# Service plan for the simple Web App (F1: Free tier)
resource "azurerm_service_plan" "webapp_plan" {
  name                = "${var.codebundle}-webapp-plan"
  location            = azurerm_resource_group.web_rg.location
  resource_group_name = azurerm_resource_group.web_rg.name
  os_type             = "Linux"
  sku_name            = "F1"
}

# Single Linux Web App
resource "azurerm_linux_web_app" "simple_web_app" {
  name                = "${var.codebundle}-webapp"
  location            = azurerm_resource_group.web_rg.location
  resource_group_name = azurerm_resource_group.web_rg.name
  service_plan_id     = azurerm_service_plan.webapp_plan.id

  site_config {
    always_on = false
  }

  tags = var.tags
}

###############################################################################
# Storage Account for the Function App - now with random suffix
###############################################################################
resource "azurerm_storage_account" "function_storage" {
  # Storage Account names must be 3 to 24 chars, all-lowercase,
  # and globally unique, so we keep it short.
  name                     = "rwapsfuncstor${random_string.storage_suffix.result}"
  resource_group_name      = azurerm_resource_group.function_rg.name
  location                 = azurerm_resource_group.function_rg.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  account_kind             = "StorageV2"
  tags                     = var.tags
}

########################################
# APPLICATION INSIGHTS FOR MONITORING
########################################

resource "azurerm_log_analytics_workspace" "function_workspace" {
  name                = "${var.codebundle}-log-analytics"
  location            = azurerm_resource_group.function_rg.location
  resource_group_name = azurerm_resource_group.function_rg.name
  sku                 = "PerGB2018"
  retention_in_days   = 30
  tags                = var.tags
}

resource "azurerm_application_insights" "function_insights" {
  name                = "${var.codebundle}-app-insights"
  location            = azurerm_resource_group.function_rg.location
  resource_group_name = azurerm_resource_group.function_rg.name
  workspace_id        = azurerm_log_analytics_workspace.function_workspace.id
  application_type    = "web"
  tags                = var.tags
}

########################################
# FUNCTION APP (CONSUMPTION PLAN)
########################################

# Consumption plan (Y1)
resource "azurerm_service_plan" "function_plan" {
  name                = "${var.codebundle}-function-consumption"
  location            = azurerm_resource_group.function_rg.location
  resource_group_name = azurerm_resource_group.function_rg.name
  os_type             = "Linux"
  sku_name            = "Y1"
}

resource "azurerm_linux_function_app" "function_app_consumption" {
  name                       = "${var.codebundle}-func-consumption"
  location                   = azurerm_resource_group.function_rg.location
  resource_group_name        = azurerm_resource_group.function_rg.name
  service_plan_id            = azurerm_service_plan.function_plan.id
  storage_account_name       = azurerm_storage_account.function_storage.name
  storage_account_access_key = azurerm_storage_account.function_storage.primary_access_key

  app_settings = {
    "FUNCTIONS_WORKER_RUNTIME"              = "node"
    "WEBSITE_NODE_DEFAULT_VERSION"          = "~18"
    "APPINSIGHTS_INSTRUMENTATIONKEY"        = azurerm_application_insights.function_insights.instrumentation_key
    "APPLICATIONINSIGHTS_CONNECTION_STRING" = azurerm_application_insights.function_insights.connection_string
  }

  site_config {
    application_stack {
      node_version = "18"
    }
  }

  identity {
    type = "SystemAssigned"
  }

  tags = var.tags
}

########################################
# FUNCTION APP (PREMIUM PLAN)
########################################

# Premium plan (EP1)
resource "azurerm_service_plan" "function_plan_premium" {
  name                = "${var.codebundle}-function-prem"
  location            = azurerm_resource_group.function_rg.location
  resource_group_name = azurerm_resource_group.function_rg.name
  os_type             = "Linux"
  sku_name            = "EP1" # Premium plan
}

resource "azurerm_linux_function_app" "function_app_premium" {
  name                       = "${var.codebundle}-func-premium"
  location                   = azurerm_resource_group.function_rg.location
  resource_group_name        = azurerm_resource_group.function_rg.name
  service_plan_id            = azurerm_service_plan.function_plan_premium.id
  storage_account_name       = azurerm_storage_account.function_storage.name
  storage_account_access_key = azurerm_storage_account.function_storage.primary_access_key

  app_settings = {
    "FUNCTIONS_WORKER_RUNTIME"              = "node"
    "WEBSITE_NODE_DEFAULT_VERSION"          = "~18"
    "APPINSIGHTS_INSTRUMENTATIONKEY"        = azurerm_application_insights.function_insights.instrumentation_key
    "APPLICATIONINSIGHTS_CONNECTION_STRING" = azurerm_application_insights.function_insights.connection_string
  }

  site_config {
    application_stack {
      node_version = "18"
    }
  }

  identity {
    type = "SystemAssigned"
  }

  tags = var.tags
}

########################################
# OUTPUTS
########################################

# Web App URL (we won't run function tests on this)
output "web_app_url" {
  value = azurerm_linux_web_app.simple_web_app.default_hostname
}

# Consumption Function App URL
output "function_app_consumption_url" {
  value = azurerm_linux_function_app.function_app_consumption.default_hostname
}

# Premium Function App URL
output "function_app_premium_url" {
  value = azurerm_linux_function_app.function_app_premium.default_hostname
}

# Resource group names
output "webapp_resource_group" {
  value = azurerm_resource_group.web_rg.name
}

output "function_resource_group" {
  value = azurerm_resource_group.function_rg.name
}

# Application Insights details
output "application_insights_name" {
  value = azurerm_application_insights.function_insights.name
}

output "log_analytics_workspace_name" {
  value = azurerm_log_analytics_workspace.function_workspace.name
}

# Subscription ID for tests
output "subscription_id" {
  value = data.azurerm_subscription.current.subscription_id
}
