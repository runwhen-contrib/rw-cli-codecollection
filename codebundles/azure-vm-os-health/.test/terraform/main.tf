# Configure Azure provider
terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "4.18.0"
    }
  }
}

provider "azurerm" {
  features {
    key_vault {
      purge_soft_delete_on_destroy    = true
      recover_soft_deleted_key_vaults = true
    }
  }
}

provider "azuread" {}

# Create a resource group
resource "azurerm_resource_group" "test_rg" {
  name     = var.resource_group
  location = var.location
  tags     = var.tags
}

# Create a virtual network
resource "azurerm_virtual_network" "test_vnet" {
  name                = "test-vnet"
  address_space       = ["10.0.0.0/16"]
  location            = azurerm_resource_group.test_rg.location
  resource_group_name = azurerm_resource_group.test_rg.name
}

# Create a subnet
resource "azurerm_subnet" "test_subnet" {
  name                 = "test-subnet"
  resource_group_name  = azurerm_resource_group.test_rg.name
  virtual_network_name = azurerm_virtual_network.test_vnet.name
  address_prefixes     = ["10.0.1.0/24"]
}

# Create a public IP
resource "azurerm_public_ip" "test_pip" {
  name                = "test-pip"
  location            = azurerm_resource_group.test_rg.location
  resource_group_name = azurerm_resource_group.test_rg.name
  allocation_method   = "Static"
  sku                 = "Standard"
}

# Create a network interface
resource "azurerm_network_interface" "test_nic" {
  name                = "test-nic"
  location            = azurerm_resource_group.test_rg.location
  resource_group_name = azurerm_resource_group.test_rg.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.test_subnet.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.test_pip.id
  }
}

# Create a virtual machine
resource "azurerm_linux_virtual_machine" "test_vm" {
  name                = "test-vm"
  resource_group_name = azurerm_resource_group.test_rg.name
  location            = azurerm_resource_group.test_rg.location
  size                = "Standard_B1s"
  admin_username      = "adminuser"
  network_interface_ids = [
    azurerm_network_interface.test_nic.id,
  ]

  admin_ssh_key {
    username   = "adminuser"
    public_key = tls_private_key.vm_key.public_key_openssh
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
    disk_size_gb         = 30
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "UbuntuServer"
    sku       = "18.04-LTS"
    version   = "latest"
  }

  tags = var.tags
}

# Create a second VM with high disk usage for testing
resource "azurerm_linux_virtual_machine" "high_usage_vm" {
  name                = "high-usage-vm"
  resource_group_name = azurerm_resource_group.test_rg.name
  location            = azurerm_resource_group.test_rg.location
  size                = "Standard_B1s"
  admin_username      = "adminuser"
  network_interface_ids = [
    azurerm_network_interface.high_usage_nic.id,
  ]

  admin_ssh_key {
    username   = "adminuser"
    public_key = tls_private_key.vm_key.public_key_openssh
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
    disk_size_gb         = 30
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "UbuntuServer"
    sku       = "18.04-LTS"
    version   = "latest"
  }

  custom_data = base64encode(<<-EOF
    #!/bin/bash
    # Fill disk to simulate high usage
    mkdir -p /tmp/diskfill
    dd if=/dev/zero of=/tmp/diskfill/largefile bs=1M count=20000 || true
    EOF
  )

  tags = var.tags
}

# Create a network interface for the high usage VM
resource "azurerm_network_interface" "high_usage_nic" {
  name                = "high-usage-nic"
  location            = azurerm_resource_group.test_rg.location
  resource_group_name = azurerm_resource_group.test_rg.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.test_subnet.id
    private_ip_address_allocation = "Dynamic"
  }
}

# Create a Windows VM to test OS filtering
resource "azurerm_windows_virtual_machine" "windows_test_vm" {
  name                = "windows-test-vm"
  resource_group_name = azurerm_resource_group.test_rg.name
  location            = azurerm_resource_group.test_rg.location
  size                = "Standard_B1s"
  admin_username      = "adminuser"
  admin_password      = "P@ssw0rd123!"
  network_interface_ids = [
    azurerm_network_interface.windows_nic.id,
  ]

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
    disk_size_gb         = 30
  }

  source_image_reference {
    publisher = "MicrosoftWindowsServer"
    offer     = "WindowsServer"
    sku       = "2019-Datacenter"
    version   = "latest"
  }

  tags = var.tags
}

# Create a network interface for the Windows VM
resource "azurerm_network_interface" "windows_nic" {
  name                = "windows-nic"
  location            = azurerm_resource_group.test_rg.location
  resource_group_name = azurerm_resource_group.test_rg.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.test_subnet.id
    private_ip_address_allocation = "Dynamic"
  }
}

# Create a stopped Linux VM to test VM status handling
resource "azurerm_linux_virtual_machine" "stopped_vm" {
  name                = "stopped-vm"
  resource_group_name = azurerm_resource_group.test_rg.name
  location            = azurerm_resource_group.test_rg.location
  size                = "Standard_B1s"
  admin_username      = "adminuser"
  network_interface_ids = [
    azurerm_network_interface.stopped_nic.id,
  ]

  admin_ssh_key {
    username   = "adminuser"
    public_key = tls_private_key.vm_key.public_key_openssh
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
    disk_size_gb         = 30
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "UbuntuServer"
    sku       = "18.04-LTS"
    version   = "latest"
  }

  tags = var.tags
}

# Create a network interface for the stopped VM
resource "azurerm_network_interface" "stopped_nic" {
  name                = "stopped-nic"
  location            = azurerm_resource_group.test_rg.location
  resource_group_name = azurerm_resource_group.test_rg.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.test_subnet.id
    private_ip_address_allocation = "Dynamic"
  }
}

# Create a VM with a name that should be included by default patterns
resource "azurerm_linux_virtual_machine" "web_server_vm" {
  name                = "web-server-01"
  resource_group_name = azurerm_resource_group.test_rg.name
  location            = azurerm_resource_group.test_rg.location
  size                = "Standard_B1s"
  admin_username      = "adminuser"
  network_interface_ids = [
    azurerm_network_interface.web_nic.id,
  ]

  admin_ssh_key {
    username   = "adminuser"
    public_key = tls_private_key.vm_key.public_key_openssh
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
    disk_size_gb         = 30
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "UbuntuServer"
    sku       = "18.04-LTS"
    version   = "latest"
  }

  tags = var.tags
}

# Create a network interface for the web server VM
resource "azurerm_network_interface" "web_nic" {
  name                = "web-nic"
  location            = azurerm_resource_group.test_rg.location
  resource_group_name = azurerm_resource_group.test_rg.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.test_subnet.id
    private_ip_address_allocation = "Dynamic"
  }
}

# Create a VM with a name that should be excluded by default patterns
resource "azurerm_linux_virtual_machine" "test_excluded_vm" {
  name                = "test-excluded-vm"
  resource_group_name = azurerm_resource_group.test_rg.name
  location            = azurerm_resource_group.test_rg.location
  size                = "Standard_B1s"
  admin_username      = "adminuser"
  network_interface_ids = [
    azurerm_network_interface.excluded_nic.id,
  ]

  admin_ssh_key {
    username   = "adminuser"
    public_key = tls_private_key.vm_key.public_key_openssh
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
    disk_size_gb         = 30
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "UbuntuServer"
    sku       = "18.04-LTS"
    version   = "latest"
  }

  tags = var.tags
}

# Create a network interface for the excluded VM
resource "azurerm_network_interface" "excluded_nic" {
  name                = "excluded-nic"
  location            = azurerm_resource_group.test_rg.location
  resource_group_name = azurerm_resource_group.test_rg.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.test_subnet.id
    private_ip_address_allocation = "Dynamic"
  }
}

resource "tls_private_key" "vm_key" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "local_file" "private_key" {
  content         = tls_private_key.vm_key.private_key_pem
  filename        = "${path.module}/generated_id_rsa"
  file_permission = "0600"
}

# Output the resource group name
output "resource_group_name" {
  value = azurerm_resource_group.test_rg.name
}

# Output the VM names with their types
output "vm_names" {
  value = [
    azurerm_linux_virtual_machine.test_vm.name,
    azurerm_linux_virtual_machine.high_usage_vm.name,
    azurerm_windows_virtual_machine.windows_test_vm.name,
    azurerm_linux_virtual_machine.stopped_vm.name,
    azurerm_linux_virtual_machine.web_server_vm.name,
    azurerm_linux_virtual_machine.test_excluded_vm.name
  ]
}

# Output VM details for testing
output "vm_details" {
  value = {
    linux_vms = [
      azurerm_linux_virtual_machine.test_vm.name,
      azurerm_linux_virtual_machine.high_usage_vm.name,
      azurerm_linux_virtual_machine.stopped_vm.name,
      azurerm_linux_virtual_machine.web_server_vm.name,
      azurerm_linux_virtual_machine.test_excluded_vm.name
    ]
    windows_vms = [
      azurerm_windows_virtual_machine.windows_test_vm.name
    ]
    all_vms = [
      azurerm_linux_virtual_machine.test_vm.name,
      azurerm_linux_virtual_machine.high_usage_vm.name,
      azurerm_windows_virtual_machine.windows_test_vm.name,
      azurerm_linux_virtual_machine.stopped_vm.name,
      azurerm_linux_virtual_machine.web_server_vm.name,
      azurerm_linux_virtual_machine.test_excluded_vm.name
    ]
  }
}
