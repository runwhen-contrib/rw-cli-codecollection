# Resource Group
resource "azurerm_resource_group" "test" {
  name     = var.resource_group
  location = var.location
  tags     = var.tags
}

####################
# Role Assignments #
####################
resource "azurerm_role_assignment" "reader" {
  scope                = azurerm_resource_group.test.id
  role_definition_name = "Reader"
  principal_id         = var.sp_principal_id
}

resource "azurerm_role_assignment" "website-contributor" {
  scope                = azurerm_resource_group.test.id
  role_definition_name = "Website Contributor"
  principal_id         = var.sp_principal_id
}

#########################
# App Service Plans/Web #
#########################
resource "azurerm_service_plan" "f1" {
  name                = "${var.codebundle}-f1"
  location            = azurerm_resource_group.test.location
  resource_group_name = azurerm_resource_group.test.name
  os_type             = "Linux"
  sku_name            = "F1"
}

resource "azurerm_linux_web_app" "app_service_01" {
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

resource "azurerm_linux_web_app" "app_service_02" {
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

############################
# Minimal APIM (Developer) #
############################
resource "azurerm_api_management" "apim" {
  name                = "${var.codebundle}-apim"
  location            = azurerm_resource_group.test.location
  resource_group_name = azurerm_resource_group.test.name
  publisher_name      = "Example Publisher"
  publisher_email     = "publisher@example.com"
  sku_name            = "Developer_1"
  tags                = var.tags
}

##############################################
# Sample API in APIM pointing to our Web App #
##############################################

# Example: Point to the B1 App Service as the primary backend
resource "azurerm_api_management_api" "sample_api" {
  name                = "${var.codebundle}-test-api"
  api_management_name = azurerm_api_management.apim.name
  resource_group_name = azurerm_api_management.apim.resource_group_name
  revision            = "1"
  display_name        = "Sample API"
  path                = "sample"
  protocols           = ["https"]
  service_url         = "https://${azurerm_linux_web_app.app_service_02.default_hostname}"
}

# Add a "happy" path
resource "azurerm_api_management_api_operation" "op_ok" {
  operation_id        = "OkOperation"
  api_name            = azurerm_api_management_api.sample_api.name
  api_management_name = azurerm_api_management.apim.name
  resource_group_name = azurerm_resource_group.test.name

  display_name = "Ok"
  method       = "GET"
  url_template = "ok"
}

# Add a "broken" path
resource "azurerm_api_management_api_operation" "op_fail" {
  operation_id        = "FailOperation"
  api_name            = azurerm_api_management_api.sample_api.name
  api_management_name = azurerm_api_management.apim.name
  resource_group_name = azurerm_resource_group.test.name

  display_name = "Fail"
  method       = "GET"
  url_template = "fail"
}

##################
# Output Values  #
##################
output "f1-app_service_url" {
  value = azurerm_linux_web_app.app_service_01.default_hostname
}

output "b1-app_service_url" {
  value = azurerm_linux_web_app.app_service_02.default_hostname
}

output "apim_gateway_url" {
  value = azurerm_api_management.apim.gateway_url
}

output "resource_group" {
  value = azurerm_resource_group.test.name
}