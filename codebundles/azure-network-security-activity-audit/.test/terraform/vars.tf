variable "resource_group" {
  type = string
}

variable "location" {
  type    = string
  default = "East US"
}

variable "subscription_id" {
  type = string
}

variable "tenant_id" {
  type = string
}

variable "tags" {
  type = map(string)
}
