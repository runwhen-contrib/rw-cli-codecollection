# Terraform backend configuration
# Uncomment and configure for remote state management
# terraform {
#   backend "azurerm" {
#     resource_group_name  = "terraform-state-rg"
#     storage_account_name = "terraformstate"
#     container_name       = "tfstate"
#     key                  = "azure-devops-organization-health-test.terraform.tfstate"
#   }
# } 