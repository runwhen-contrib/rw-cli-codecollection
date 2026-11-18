data "azurerm_client_config" "current" {}

resource "random_id" "suffix" {
  byte_length = 2
}

resource "azurerm_resource_group" "rg" {
  name     = "${var.resource_group}-${random_id.suffix.hex}"
  location = var.location
  tags     = var.tags
}

resource "azurerm_network_security_group" "nsg" {
  name                = "rwtest-nsg-${random_id.suffix.hex}"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  tags                = var.tags

  security_rule {
    name                       = "AllowSSH"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

output "resource_group_name" {
  value = azurerm_resource_group.rg.name
}

output "nsg_name" {
  value = azurerm_network_security_group.nsg.name
}

output "subscription_id" {
  value = data.azurerm_client_config.current.subscription_id
}
