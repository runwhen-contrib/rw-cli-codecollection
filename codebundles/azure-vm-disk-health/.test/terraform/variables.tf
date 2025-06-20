variable "resource_group" {
  description = "Name of the resource group"
  type        = string
  default     = "test-vm-rg"
}

variable "location" {
  description = "Azure region for resources"
  type        = string
  default     = "eastus"
}

variable "tags" {
  description = "Tags to apply to resources"
  type        = map(string)
  default = {
    environment = "test"
    purpose     = "disk-health-testing"
  }
}
