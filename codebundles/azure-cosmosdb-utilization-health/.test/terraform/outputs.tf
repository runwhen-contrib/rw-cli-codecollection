output "cosmosdb_account_name" {
  value = azurerm_cosmosdb_account.test.name
}

output "resource_group_name" {
  value = azurerm_resource_group.test_rg.name
}

output "subscription_hint" {
  value = "Use the same subscription ID as Terraform provider context for RunWhen config."
}
