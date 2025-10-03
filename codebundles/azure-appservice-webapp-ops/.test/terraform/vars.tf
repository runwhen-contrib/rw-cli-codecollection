variable "resource_group" {
  type = string
}

variable "location" {
  type    = string
  default = "Canada Central"
}

variable "tags" {
  type = map(string)
}

variable "sp_principal_id" {
  type = string
}

variable "tenant_id" {
  type = string
}

variable "codebundle" {
  type = string
}

variable "codecollection" {
  type = string
}