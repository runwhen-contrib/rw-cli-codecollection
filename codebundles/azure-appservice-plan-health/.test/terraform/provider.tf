terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "4.18.0"
    }
  }
}

provider "azurerm" {
  features {}
}

provider "azuread" {}