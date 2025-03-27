variable "resource_group" {
  type        = string
  description = "Name of the resource group to create/use."
}

variable "location" {
  type        = string
  description = "Azure location for all resources."
}

variable "tags" {
  type        = map(string)
  description = "Tags to apply to resources."
  default     = {}
}

variable "sp_principal_id" {
  type        = string
  description = "Client (service principal) ID with access to the resources."
}

variable "codebundle" {
  type        = string
  description = "Base name for your resources."
  default     = "example-bundle"
}


