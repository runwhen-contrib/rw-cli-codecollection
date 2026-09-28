terraform {
  required_version = ">= 1.3.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }
}

provider "azurerm" {
  features {}
}

resource "random_string" "suffix" {
  length  = 8
  special = false
  upper   = false
}

data "azurerm_client_config" "current" {}

resource "azurerm_resource_group" "test" {
  name     = var.resource_group
  location = var.location
  tags     = var.tags
}

resource "azurerm_log_analytics_workspace" "logs" {
  name                = "${var.codebundle}-logs-${random_string.suffix.result}"
  location            = azurerm_resource_group.test.location
  resource_group_name = azurerm_resource_group.test.name
  sku                 = "PerGB2018"
  retention_in_days   = 30
  tags                = var.tags
}

resource "azurerm_storage_account" "investigation" {
  name                            = "${var.codebundle}${random_string.suffix.result}"
  resource_group_name             = azurerm_resource_group.test.name
  location                        = azurerm_resource_group.test.location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  allow_nested_items_to_be_public = true
  min_tls_version                 = "TLS1_2"
  tags                            = var.tags
}

resource "azurerm_monitor_diagnostic_setting" "blob_logs" {
  name                       = "blob-logs-to-law"
  target_resource_id         = "${azurerm_storage_account.investigation.id}/blobServices/default"
  log_analytics_workspace_id = azurerm_log_analytics_workspace.logs.id

  enabled_log {
    category = "StorageRead"
  }
  enabled_log {
    category = "StorageWrite"
  }
  enabled_log {
    category = "StorageDelete"
  }

  metric {
    category = "Transaction"
    enabled  = true
  }
}

resource "azurerm_role_assignment" "sp_reader" {
  count                = var.sp_principal_id != "" ? 1 : 0
  scope                = azurerm_storage_account.investigation.id
  role_definition_name = "Storage Blob Data Reader"
  principal_id         = var.sp_principal_id
}

resource "azurerm_role_assignment" "sp_contributor_rg" {
  count                = var.sp_principal_id != "" ? 1 : 0
  scope                = azurerm_resource_group.test.id
  role_definition_name = "Reader"
  principal_id         = var.sp_principal_id
}

resource "azurerm_storage_container" "public_test" {
  name                  = "public-test"
  storage_account_name  = azurerm_storage_account.investigation.name
  container_access_type = "blob"
}
