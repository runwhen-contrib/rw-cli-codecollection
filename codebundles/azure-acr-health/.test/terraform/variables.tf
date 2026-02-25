variable "resource_group" {
  description = "Name of the resource group"
  type        = string
  default     = "test-acr-rg"
}

variable "location" {
  description = "Azure region for resources"
  type        = string
  default     = "East US"
}

variable "codebundle" {
  description = "Name of the codebundle for resource naming"
  type        = string
  default     = "acrhealth"
}

variable "sp_principal_id" {
  description = "Service Principal Object ID for RBAC assignments"
  type        = string
  default     = ""
}

variable "subscription_id" {
  description = "Azure Subscription ID"
  type        = string
  default     = ""
}

variable "tenant_id" {
  description = "Azure Tenant ID"
  type        = string
  default     = ""
}

variable "enable_premium_acr" {
  description = "Enable Premium ACR for advanced testing (increases cost significantly)"
  type        = bool
  default     = false
}

variable "enable_geo_replication" {
  description = "Enable geo-replication for Premium ACR (additional cost)"
  type        = bool
  default     = false
}

variable "log_retention_days" {
  description = "Log Analytics retention days (minimum 30 days for cost optimization)"
  type        = number
  default     = 30
  validation {
    condition     = var.log_retention_days >= 30 && var.log_retention_days <= 730
    error_message = "Log retention must be between 30 and 730 days (Azure minimum requirement)."
  }
}

variable "enable_private_endpoint" {
  description = "Enable private endpoint for testing (additional networking cost)"
  type        = bool
  default     = false
}

variable "primary_acr_sku" {
  description = "SKU for primary ACR (Standard recommended for cost-conscious testing)"
  type        = string
  default     = "Standard"
  validation {
    condition     = contains(["Basic", "Standard", "Premium"], var.primary_acr_sku)
    error_message = "ACR SKU must be Basic, Standard, or Premium."
  }
}

variable "tags" {
  description = "Tags to apply to resources"
  type        = map(string)
  default = {
    environment = "test"
    purpose     = "acr-health-testing"
    codebundle  = "azure-acr-health"
    cost_center = "development"
    auto_delete = "7days" # Reminder to clean up
  }
}