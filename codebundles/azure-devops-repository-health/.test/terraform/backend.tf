# Terraform backend configuration
# Uncomment and configure for remote state storage

# terraform {
#   backend "azurerm" {
#     resource_group_name  = "rg-terraform-state"
#     storage_account_name = "terraformstate"
#     container_name       = "tfstate"
#     key                  = "repository-health-test.terraform.tfstate"
#   }
# } 