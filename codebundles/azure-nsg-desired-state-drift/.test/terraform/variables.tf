variable "resource_group" {
  type        = string
  description = "Base name for the test resource group"
}

variable "location" {
  type    = string
  default = "East US"
}

variable "tags" {
  type = map(string)
}
