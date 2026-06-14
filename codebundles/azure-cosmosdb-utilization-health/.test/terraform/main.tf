resource "azurerm_resource_group" "test_rg" {
  name     = var.resource_group
  location = var.location
}

resource "random_string" "suffix" {
  length  = 8
  upper   = false
  special = false
}

resource "azurerm_cosmosdb_account" "test" {
  name                = "rwcosmos${random_string.suffix.result}"
  location            = azurerm_resource_group.test_rg.location
  resource_group_name = azurerm_resource_group.test_rg.name
  offer_type          = "Standard"
  kind                = "GlobalDocumentDB"

  consistency_policy {
    consistency_level = "Session"
  }

  geo_location {
    location          = azurerm_resource_group.test_rg.location
    failover_priority = 0
  }

  tags = var.tags
}
