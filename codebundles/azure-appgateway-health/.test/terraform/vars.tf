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

variable "sp_principal_id" {
  type = string
}

variable "tenant_id" {
  type = string
}

# Password for .pfx files (self-signed)
variable "ssl_cert_password" {
  type    = string
  default = "P@ssw0rd123!"
}