resource "azurerm_resource_group" "rg" {
  name     = "cloudcustodian"
  location = "East US"
}

data "azurerm_client_config" "current" {}

resource "azurerm_key_vault" "kv" {
  name                       = var.kv_name
  location                   = azurerm_resource_group.rg.location
  resource_group_name        = azurerm_resource_group.rg.name
  sku_name                   = "standard"
  enable_rbac_authorization  = false # Disable RBAC to use access policies
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  purge_protection_enabled   = false
  soft_delete_retention_days = 7 # Minimum allowed value is 7 days
  tags                       = var.tags
  access_policy {
    tenant_id               = data.azurerm_client_config.current.tenant_id
    object_id               = data.azurerm_client_config.current.object_id
    key_permissions         = ["Backup", "Create", "Decrypt", "Delete", "Encrypt", "Get", "Import", "List", "Purge", "Recover", "Restore", "Sign", "UnwrapKey", "Update", "Verify", "WrapKey", "GetRotationPolicy", "SetRotationPolicy"]
    secret_permissions      = ["Get", "List", "Set", "Delete", "Purge", "Recover"]
    certificate_permissions = ["Get", "Create", "Update", "Delete", "Recover", "Purge"]
  }
}

resource "azurerm_key_vault_secret" "expiring_secret" {
  name         = "${var.kv_name}-secret"
  value        = "ThisIsASecret"
  key_vault_id = azurerm_key_vault.kv.id

  # Set an expiration date (e.g., 1 day from now)
  expiration_date = timeadd(timestamp(), "24h")
  tags            = var.tags
}

resource "azurerm_key_vault_key" "expiring_key" {
  name         = "${var.kv_name}-key"
  key_vault_id = azurerm_key_vault.kv.id
  key_type     = "RSA"
  key_size     = 2048

  # Set an expiration date (e.g., 1 day from now)
  expiration_date = timeadd(timestamp(), "24h")

  key_opts = ["encrypt", "decrypt", "sign", "verify"]
  tags     = var.tags
}

resource "azurerm_key_vault_certificate" "expiring_cert" {
  name         = "${var.kv_name}-cert"
  key_vault_id = azurerm_key_vault.kv.id

  certificate_policy {
    issuer_parameters {
      name = "Self"
    }

    key_properties {
      exportable = true
      key_size   = 2048
      key_type   = "RSA"
      reuse_key  = true
    }

    lifetime_action {
      action {
        action_type = "AutoRenew"
      }

      trigger {
        days_before_expiry = 1
      }
    }

    secret_properties {
      content_type = "application/x-pkcs12"
    }

    x509_certificate_properties {
      key_usage = [
        "digitalSignature",
        "keyEncipherment"
      ]

      subject            = "CN=expiring-cert"
      validity_in_months = 1 # Expires in 1 month
    }
  }
  tags = var.tags
}



output "keyvault_name" {
  value = azurerm_key_vault.kv.name
}