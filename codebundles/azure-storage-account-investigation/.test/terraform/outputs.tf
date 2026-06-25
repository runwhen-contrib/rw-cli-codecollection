output "storage_account_name" {
  value       = azurerm_storage_account.investigation.name
  description = "Test storage account name"
}

output "resource_group_name" {
  value       = azurerm_resource_group.test.name
  description = "Test resource group name"
}

output "subscription_id" {
  value       = data.azurerm_client_config.current.subscription_id
  description = "Subscription ID"
}

output "log_analytics_workspace_id" {
  value       = azurerm_log_analytics_workspace.logs.id
  description = "Log Analytics workspace resource ID"
}

output "storage_account_id" {
  value       = azurerm_storage_account.investigation.id
  description = "Storage account resource ID"
}
