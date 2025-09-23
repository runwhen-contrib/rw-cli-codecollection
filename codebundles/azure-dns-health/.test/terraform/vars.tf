variable "resource_group" {
  description = "Name of the resource group"
  type        = string
  default     = "azure-dns-health"
}

variable "location" {
  description = "Azure region for resources"
  type        = string
  default     = "East US"
}

variable "tags" {
  description = "Tags to apply to resources"
  type        = map(string)
  default = {
    Environment = "test"
    Project     = "dns-health"
    ManagedBy   = "terraform"
  }
}

variable "sp_principal_id" {
  description = "Service Principal Principal ID for role assignments"
  type        = string
  default     = ""
}
