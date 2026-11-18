variable "codebundle" {
  type        = string
  description = "CodeBundle name prefix for test resources"
  default     = "storinv"
}

variable "resource_group" {
  type        = string
  description = "Resource group name for test infrastructure"
  default     = "rg-storage-account-investigation-test"
}

variable "location" {
  type        = string
  description = "Azure region"
  default     = "eastus"
}

variable "subscription_id" {
  type        = string
  description = "Azure subscription ID"
}

variable "tenant_id" {
  type        = string
  description = "Azure tenant ID"
}

variable "sp_principal_id" {
  type        = string
  description = "Service principal object ID for RBAC test assignments"
  default     = ""
}

variable "tags" {
  type = map(string)
  default = {
    purpose    = "codebundle-test"
    codebundle = "azure-storage-account-investigation"
  }
}
