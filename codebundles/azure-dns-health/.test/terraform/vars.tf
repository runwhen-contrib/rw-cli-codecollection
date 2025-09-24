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

variable "public_domain" {
  description = "Public domain for DNS testing (should be a real domain you control)"
  type        = string
  default     = "dns-health-test.azure.runwhen.com"
}

variable "parent_domain_name" {
  description = "Parent domain name for DNS delegation (e.g., azure.runwhen.com)"
  type        = string
  default     = "azure.runwhen.com"
}

variable "parent_domain_resource_group" {
  description = "Resource group containing the parent domain"
  type        = string
  default     = "nonprod-network"
}
