terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.18"
    }
  }
}

provider "azurerm" {
  features {}
}
