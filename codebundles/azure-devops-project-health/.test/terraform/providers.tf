terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0"
    }
    azuredevops = {
      source  = "microsoft/azuredevops"
      version = "~> 1.8.1"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.9.1"
    }
  }
  required_version = ">= 1.0.0"
}

provider "azurerm" {
  features {}
}

provider "azuredevops" {
  org_service_url = var.azure_devops_org_url != null ? var.azure_devops_org_url : "https://dev.azure.com/${var.azure_devops_org}"
  client_id       = var.client_id
  tenant_id       = var.tenant_id
  client_secret   = var.client_secret

}

# provider "azapi" {
# }

# provider "local" {
# }

# provider "null" {
# }
