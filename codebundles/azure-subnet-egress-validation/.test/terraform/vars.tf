variable "resource_group" {
  type = string
}

variable "location" {
  type    = string
  default = "East US"
}

variable "vnet_name" {
  type = string
}

variable "tags" {
  type = map(string)
}
