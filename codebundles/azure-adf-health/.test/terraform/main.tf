resource "random_integer" "rand" {
  min = 10000
  max = 99999
}

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

# SQL
resource "azurerm_mssql_server" "sql" {
  name                         = "adfsqlsrv${random_integer.rand.result}"
  resource_group_name          = azurerm_resource_group.rg.name
  location                     = azurerm_resource_group.rg.location
  version                      = "12.0"
  administrator_login          = "sqladminuser"
  administrator_login_password = "StrongPassword123!"
}

resource "azurerm_mssql_firewall_rule" "example" {
  name             = "AllowAll"
  server_id        = azurerm_mssql_server.sql.id
  start_ip_address = "0.0.0.0"
  end_ip_address   = "255.255.255.255"
}

resource "azurerm_mssql_database" "sqldb" {
  name                 = "adfdemodb"
  server_id            = azurerm_mssql_server.sql.id
  sku_name             = "Basic"
  collation            = "SQL_Latin1_General_CP1_CI_AS"
  max_size_gb          = 1
  storage_account_type = "Local"
  zone_redundant       = false
  geo_backup_enabled   = false
  lifecycle {
    ignore_changes = [
      geo_backup_enabled
    ]
  }
}

resource "null_resource" "create_table_and_insert_data" {
  provisioner "local-exec" {
    on_failure = continue
    command = <<EOT
      sqlcmd -S ${azurerm_mssql_server.sql.fully_qualified_domain_name} -d ${azurerm_mssql_database.sqldb.name} -U ${azurerm_mssql_server.sql.administrator_login} -P ${azurerm_mssql_server.sql.administrator_login_password} -Q "
        CREATE TABLE dbo.CustomerTransactions (
            TransactionID INT PRIMARY KEY,
            CustomerID INT,
            TransactionDate DATETIME,
            Amount DECIMAL(18, 2)
        );
        INSERT INTO dbo.CustomerTransactions (TransactionID, CustomerID, TransactionDate, Amount) VALUES
        (1, 101, '2023-10-01 10:00:00', 100.00),
        (2, 102, '2023-10-02 11:00:00', 200.00),
        (3, 103, '2023-10-03 12:00:00', 300.00);
      "
    EOT
  }

  depends_on = [
    azurerm_mssql_database.sqldb
  ]
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

resource "azurerm_data_factory_linked_service_azure_sql_database" "sql" {
  name              = "AzureSQLLS"
  data_factory_id   = azurerm_data_factory.adf.id
  connection_string = "Server=tcp:${azurerm_mssql_server.sql.fully_qualified_domain_name},1433;Initial Catalog=${azurerm_mssql_database.sqldb.name};User ID=${azurerm_mssql_server.sql.administrator_login};Password=${azurerm_mssql_server.sql.administrator_login_password};Encrypt=true;Connection Timeout=30;"
}

resource "azapi_resource" "copy_pipeline" {
  type                      = "Microsoft.DataFactory/factories/pipelines@2018-06-01"
  name                      = "copy-sql-to-blob"
  parent_id                 = azurerm_data_factory.adf.id
  schema_validation_enabled = false

  body = {
    properties = {
      activities = [
        {
          name      = "Copy data1"
          type      = "Copy"
          dependsOn = []
          policy = {
            timeout                = "0.12:00:00"
            retry                  = 0
            retryIntervalInSeconds = 30
            secureOutput           = false
            secureInput            = false
          }
          userProperties = [
            {
              name  = "Destination"
              value = "backups/daily_dump.csv"
            }
          ]
          typeProperties = {
            source = {
              type            = "AzureSqlSource"
              queryTimeout    = "02:00:00"
              isolationLevel  = "ReadCommitted"
              partitionOption = "None"
            }
            sink = {
              type         = "BlobSink"
              copyBehavior = "PreserveHierarchy"
            }
            enableStaging        = false
            dataIntegrationUnits = 4
          }
          inputs = [
            {
              referenceName = "SQLDataset"
              type          = "DatasetReference"
            }
          ]
          outputs = [
            {
              referenceName = "BlobDataset"
              type          = "DatasetReference"
            }
          ]
        }
      ]
    }
  }
  depends_on = [
    azurerm_data_factory_linked_service_azure_sql_database.sql,
    azurerm_data_factory_linked_service_azure_blob_storage.blob,
    azapi_resource.sql_dataset,
    azapi_resource.blob_dataset

  ]
}

resource "azapi_resource" "sql_dataset" {
  type                      = "Microsoft.DataFactory/factories/datasets@2018-06-01"
  name                      = "SQLDataset"
  parent_id                 = azurerm_data_factory.adf.id
  schema_validation_enabled = false

  body = {
    properties = {
      linkedServiceName = {
        referenceName = azurerm_data_factory_linked_service_azure_sql_database.sql.name
        type          = "LinkedServiceReference"
      }
      type = "AzureSqlTable"
      typeProperties = {
        tableName = var.table_name #  use default value to run this pipeline successfully
      }
    }
  }
}

resource "azapi_resource" "blob_dataset" {
  type                      = "Microsoft.DataFactory/factories/datasets@2018-06-01"
  name                      = "BlobDataset"
  parent_id                 = azurerm_data_factory.adf.id
  schema_validation_enabled = false

  body = {
    properties = {
      linkedServiceName = {
        referenceName = azurerm_data_factory_linked_service_azure_blob_storage.blob.name
        type          = "LinkedServiceReference"
      }
      type = "AzureBlob"
      typeProperties = {
        folderPath = "backups"
        fileName   = "daily_dump.csv"
        format = {
          type = "TextFormat"
        }
      }
    }
  }
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

resource "null_resource" "trigger_pipeline" {
  depends_on = [
    azapi_resource.copy_pipeline,
    azapi_resource.sql_dataset,
    azapi_resource.blob_dataset,
    azurerm_data_factory_linked_service_azure_sql_database.sql,
    azurerm_data_factory_linked_service_azure_blob_storage.blob
  ]

  provisioner "local-exec" {
    command = <<EOT
      az datafactory pipeline create-run \
        --resource-group ${azurerm_resource_group.rg.name} \
        --factory-name ${azurerm_data_factory.adf.name} \
        --name ${azapi_resource.copy_pipeline.name}
    EOT
  }
}