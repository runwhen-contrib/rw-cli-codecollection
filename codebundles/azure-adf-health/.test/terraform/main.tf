# Azure Data Factory Simulation Suite: Infrastructure + Monitoring Setup

resource "azurerm_resource_group" "rg" {
  name     = var.resource_group
  location = var.location
}

resource "azurerm_log_analytics_workspace" "log" {
  name                = "${var.name}-law"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  sku                 = "PerGB2018"
}

resource "azurerm_storage_account" "storage" {
  name                     = "adfsimstorage${random_integer.rand.result}"
  resource_group_name      = azurerm_resource_group.rg.name
  location                 = azurerm_resource_group.rg.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
}

resource "random_integer" "rand" {
  min = 10000
  max = 99999
}

resource "azurerm_data_factory" "adf" {
  name                = "${var.name}-adf"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
}

resource "azurerm_data_factory_linked_service_azure_blob_storage" "blob" {
  name              = "BlobLS"
  data_factory_id   = azurerm_data_factory.adf.id
  connection_string = azurerm_storage_account.storage.primary_connection_string
}

resource "azapi_resource" "fail_sim_pipeline" {
  type                      = "Microsoft.DataFactory/factories/pipelines@2018-06-01"
  name                      = "fail-sim-pipeline"
  parent_id                 = azurerm_data_factory.adf.id
  schema_validation_enabled = false
  body = {
    properties : {
      activities : [
        {
          name : "FailStep",
          type : "Fail",
          typeProperties : {
            message : "Simulated failure for monitoring.",
            errorCode : 500
          }
        }
      ]
    }
  }
  depends_on = [azurerm_data_factory.adf]
}

resource "azurerm_monitor_diagnostic_setting" "adf_diag" {
  name                       = "${var.name}-diagnostics"
  target_resource_id         = azurerm_data_factory.adf.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.log.id

  enabled_log {
    category = "PipelineRuns"
  }

  enabled_log {
    category = "ActivityRuns"
  }

  metric {
    category = "AllMetrics"
    enabled  = true
  }
}
