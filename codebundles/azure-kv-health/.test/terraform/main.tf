resource "azurerm_resource_group" "rg" {
  name     = "cloudcustodian"
  location = "East US"
}

data "azurerm_client_config" "current" {}

resource "azurerm_key_vault" "kv" {
  name                       = "yoko-ono-kv"
  location                   = azurerm_resource_group.rg.location
  resource_group_name        = azurerm_resource_group.rg.name
  sku_name                   = "standard"
  enable_rbac_authorization  = true
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  purge_protection_enabled   = false
  soft_delete_retention_days = 7


  access_policy {
    tenant_id           = data.azurerm_client_config.current.tenant_id
    object_id           = data.azurerm_client_config.current.object_id
    key_permissions     = ["Get", ]
    secret_permissions  = ["Get", ]
    storage_permissions = ["Get", ]
  }
}

output "keyvault_name" {
  value = azurerm_key_vault.kv.name
}