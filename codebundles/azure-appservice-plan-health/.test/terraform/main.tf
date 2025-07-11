resource "azurerm_resource_group" "test_rg" {
  name     = var.resource_group
  location = var.location
}

resource "random_string" "suffix" {
  length  = 8
  upper   = false
  special = false
}

resource "azurerm_app_service_plan" "test_plan" {
  name                = "asp-${random_string.suffix.result}"
  location            = azurerm_resource_group.test_rg.location
  resource_group_name = azurerm_resource_group.test_rg.name

  sku {
    tier = "Basic"
    size = "B1"
  }

  tags = var.tags
}