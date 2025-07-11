variable "resource_group" {
  type = string
}

variable "location" {
  type    = string
  default = "East US"
}


variable "tags" {
  type = map(string)
}