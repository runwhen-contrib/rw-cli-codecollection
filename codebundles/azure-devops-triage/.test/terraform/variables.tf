variable "azure_devops_org" {
  description = "Azure DevOps organization name"
  type        = string
}

variable "azure_devops_org_url" {
  description = "Azure DevOps organization URL"
  type        = string
  default     = null
}

variable "service_principal_id" {
  description = "Service Principal ID for Azure DevOps service connection"
  type        = string
  sensitive   = true
}

# variable "service_principal_key" {
#   description = "Service Principal Key for Azure DevOps service connection"
#   type        = string
#   sensitive   = true
# }
variable "client_id" {
  description = "Client ID for Azure DevOps service connection"
  type        = string
  sensitive   = true
}

variable "client_secret" {
  description = "Client Secret for Azure DevOps service connection"
  type        = string
  sensitive   = true
}

variable "tenant_id" {
  description = "Azure AD tenant ID for service principal authentication"
  type        = string
  sensitive   = true
}

# variable "subscription_id" {
#   description = "Azure subscription ID"
#   type        = string
#   sensitive   = true
# }



variable "tags" {
  description = "Tags to apply to resources"
  type        = map(string)
  default     = {}
}

variable "resource_group" {
  description = "Name of the Azure resource group"
  type        = string
}

variable "location" {
  description = "Azure region where resources will be created"
  type        = string
}

variable "trigger_pipelines" {
  description = "Whether to trigger the pipelines after creation"
  type        = bool
  default     = true
}
