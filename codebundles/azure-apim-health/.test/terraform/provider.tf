terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~>3.0"
    }
  }
  required_version = ">=1.0"
}

provider "azurerm" {
  features {}
}

# Pull subscription info from the current CLI session
data "azurerm_subscription" "current" {}

# Pull tenant and user details from the current CLI session
data "azurerm_client_config" "current" {}